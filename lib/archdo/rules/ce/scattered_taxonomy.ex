defmodule Archdo.Rules.CE.ScatteredTaxonomy do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-26. Cross-cutting call sites whose
  # event names are spelled inconsistently across modules — e.g.
  # `[:user, :created]` here, `[:users, :create]` there, `[:user,
  # :create]` elsewhere — all referring to the same conceptual event.
  # Downstream consumers (dashboards, log aggregators, audit pipelines)
  # must know about all variants; renaming is N changes.

  alias Archdo.{AST, Diagnostic, Fix, Naming}

  # Cluster fires when at least this many DISTINCT surface forms map
  # to the same canonical key across at least 2 modules.
  @min_cluster_distinct 3
  @min_cluster_modules 2

  @impl true
  def id, do: "CE-26"

  @impl true
  def description,
    do: "Scattered cross-cutting taxonomy — same conceptual event named inconsistently"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level. Returns one Diagnostic per scattered-name cluster.
  """
  @spec analyze_project([{String.t(), Macro.t()}]) :: [Diagnostic.t()]
  def analyze_project(file_asts) do
    production_asts = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)

    occurrences = collect_occurrences(production_asts)

    occurrences
    |> Enum.group_by(fn {_kind, _surface, canon, _module, _file, _line} -> canon end)
    |> Enum.flat_map(fn {canon, occs} ->
      surfaces = occs |> Enum.map(fn {_, s, _, _, _, _} -> s end) |> Enum.uniq()
      modules = occs |> Enum.map(fn {_, _, _, m, _, _} -> m end) |> Enum.uniq()

      case length(surfaces) >= @min_cluster_distinct and
             length(modules) >= @min_cluster_modules do
        true -> [build_diagnostic(canon, surfaces, occs)]
        false -> []
      end
    end)
  end

  # --- occurrence collection ---

  # Each occurrence: {kind, surface_form, canonical_key, module, file, line}
  # kind ∈ :telemetry | :logger
  defp collect_occurrences(file_asts) do
    Enum.flat_map(file_asts, fn {file, ast} ->
      module = AST.extract_module_name(ast)

      ast
      |> find_calls()
      |> Enum.flat_map(fn {kind, surface, line} ->
        case canonical(kind, surface) do
          nil -> []
          canon -> [{kind, surface, canon, module, file, line}]
        end
      end)
    end)
  end

  # Walk the AST looking for telemetry/logger calls. Handles both the
  # raw shape (test ASTs from Code.string_to_quoted/1) and the
  # literal_encoder-wrapped shape (runner uses literal_encoder which
  # wraps every atom/string as `{:__block__, _, [literal]}`).
  defp find_calls(ast) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        {{:., meta, [target, fun]}, _, [arg | _rest]} = node, acc ->
          case classify(AST.unwrap_atom(target), fun, unwrap_arg(arg)) do
            nil -> {node, acc}
            {kind, surface} -> {node, [{kind, surface, AST.line(meta)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  # Lists of literals come through as `{:__block__, _, [list]}` under the
  # encoder; the inner list's elements are themselves wrapped atoms.
  defp unwrap_arg({:__block__, _, [s]}) when is_binary(s), do: s
  defp unwrap_arg({:__block__, _, [list]}) when is_list(list), do: Enum.map(list, &AST.unwrap_atom/1)
  defp unwrap_arg(other), do: other

  defp classify(:telemetry, fun, name) when fun in [:execute, :span] and is_list(name),
    do: {:telemetry, name}

  defp classify({:__aliases__, _, [:Logger]}, fun, s)
       when fun in [:info, :debug, :warning, :error, :notice] and is_binary(s),
       do: {:logger, s}

  defp classify(_, _, _), do: nil

  # Canonicalize a name to detect synonym clusters. Returns nil if the
  # surface form isn't a recognizable event-name shape.
  #
  # Telemetry surfaces are AST lists of atoms: [:user, :created] →
  # canonical = sorted-stemmed token set "create user".
  # Logger surfaces are strings: "user_created" / "user.create" /
  # "created_user" → tokenize on _.- and stem.
  defp canonical(:telemetry, name) when is_list(name) do
    name
    |> Enum.flat_map(&atom_to_tokens/1)
    |> tokens_to_canonical()
  end

  defp canonical(:logger, name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.split(~r/[\s._\-:\/]+/, trim: true)
    |> Enum.map(&Naming.stem/1)
    |> tokens_to_canonical()
  end

  defp canonical(_, _), do: nil

  defp atom_to_tokens(a) when is_atom(a) do
    a
    |> Atom.to_string()
    |> String.downcase()
    |> String.split(~r/[\s._\-:\/]+/, trim: true)
    |> Enum.map(&Naming.stem/1)
  end

  defp atom_to_tokens(_), do: []

  defp tokens_to_canonical([]), do: nil
  defp tokens_to_canonical(tokens), do: tokens |> Enum.sort() |> Enum.uniq() |> Enum.join(" ")

  defp build_diagnostic(canon, surfaces, occs) do
    surface_repr =
      surfaces
      |> Enum.map(&format_surface/1)
      |> Enum.sort()
      |> Enum.take(5)
      |> Enum.join(", ")

    {_, _, _, _, file, line} = hd(occs)

    Diagnostic.warning("CE-26",
      title: "Scattered cross-cutting taxonomy",
      message:
        "Cross-cutting event '#{canon}' is spelled #{length(surfaces)} different ways " <>
          "across #{length(occs)} call sites: #{surface_repr}",
      why:
        "Downstream consumers — dashboards, log aggregators, audit pipelines, alerting " <>
          "rules — must know about all variants. Adding a new variant breaks dashboards " <>
          "silently; renaming requires coordinated change across producer code, " <>
          "dashboards, alerts. The cross-cutting concern has scattered without a " <>
          "unifying taxonomy. Every change to the event taxonomy is now N changes.",
      alternatives: [
        Fix.new(
          summary: "Centralize the event taxonomy",
          detail:
            "Define a `MyApp.Telemetry` module with @event constants or an " <>
              "`event_name/1` function exposing canonical names; route all " <>
              "`:telemetry.execute` calls through it.",
          applies_when: "The cluster is telemetry events."
        ),
        Fix.new(
          summary: "Define structured logging helpers per concept",
          detail:
            "`MyApp.Log.user_created(user)` — encodes the canonical key set in one " <>
              "place. Callers use the helper, not raw `Logger.info(\"user_created\", ...)`.",
          applies_when: "The cluster is log lines / metadata keys."
        ),
        Fix.new(
          summary: "Mark allowed variant set explicitly",
          detail:
            "If the variants are intentional (external schema, audit feed consumed " <>
              "by another team), add a `# archdo:allow CE-26 reason: ...` comment at " <>
              "the cluster's call sites.",
          applies_when: "The variants are intentional and documented."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-26"],
      context: %{
        canonical: canon,
        surface_count: length(surfaces),
        call_sites: length(occs),
        examples: Enum.take(Enum.map(surfaces, &format_surface/1), 5)
      },
      file: file,
      line: line
    )
  end

  defp format_surface(name) when is_list(name), do: inspect(name)
  defp format_surface(name) when is_binary(name), do: ~s|"#{name}"|
  defp format_surface(other), do: inspect(other)
end
