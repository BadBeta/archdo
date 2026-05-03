defmodule Archdo.Rules.Boundary.AtomAtBoundary do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.20"

  @impl true
  def description,
    do: "Atom creation at a boundary module — untrusted input flows here, RCE/DoS class"

  @impl true
  def cleanup_pass, do: 3

  # §§ elixir-planning: §6.5 — boundary classification by file convention.
  # Rule fires only at the surfaces where untrusted input enters: Phoenix
  # controller / channel / live, Oban worker, custom plug. Domain context
  # modules (lib/my_app/accounts.ex) are NOT in scope — the existing 5.24
  # rule fires there at info severity.
  @boundary_markers [
    "_controller.ex",
    "/controllers/",
    "_channel.ex",
    "/channels/",
    "_live.ex",
    "/live/",
    "/plugs/",
    "_plug.ex",
    "/workers/",
    "_worker.ex"
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case in_scope?(file) do
      true -> find_atom_creation(file, ast)
      false -> []
    end
  end

  defp in_scope?(file) do
    not AST.test_file?(file) and
      not String.contains?(file, "/mix/tasks/") and
      not String.contains?(file, "/tasks/") and
      AST.path_contains_any?(file, @boundary_markers)
  end

  defp find_atom_creation(file, ast) do
    {_, hits} = Macro.prewalk(ast, [], fn node, acc -> collect(node, acc, file) end)
    Enum.reverse(hits)
  end

  # §§ elixir-implementing: §5.2, §7.6 — multi-clause head dispatch on AST shape.

  # `String.to_atom` call (rule-under-implementation; not a real call site)
  defp collect(
         {{:., _, [{:__aliases__, _, [:String]}, :to_atom]}, meta, _args} = node,
         acc,
         file
       ) do
    {node, [diag(:string_to_atom, file, meta) | acc]}
  end

  # :erlang.binary_to_atom(_, _) / :erlang.binary_to_atom(_)
  defp collect({{:., _, [:erlang, :binary_to_atom]}, meta, _args} = node, acc, file) do
    {node, [diag(:binary_to_atom, file, meta) | acc]}
  end

  # :erlang.list_to_atom(_)
  defp collect({{:., _, [:erlang, :list_to_atom]}, meta, _args} = node, acc, file) do
    {node, [diag(:list_to_atom, file, meta) | acc]}
  end

  # :"prefix_#{var}" — atom interpolation
  defp collect(
         {:"::", meta, [{{:., _, [Kernel, :to_string]}, _, _}, {:atom, _, _}]} = node,
         acc,
         file
       ) do
    {node, [diag(:atom_interpolation, file, meta) | acc]}
  end

  defp collect(node, acc, _file), do: {node, acc}

  defp diag(kind, file, meta) do
    {primitive, primitive_msg} =
      case kind do
        :string_to_atom -> {"String.to_atom/1", "String.to_atom/1"}
        :binary_to_atom -> {":erlang.binary_to_atom", ":erlang.binary_to_atom/1,2"}
        :list_to_atom -> {":erlang.list_to_atom", ":erlang.list_to_atom/1"}
        :atom_interpolation -> {"atom interpolation", ":\"prefix_\#{var}\""}
      end

    Diagnostic.error("1.20",
      title: "#{primitive} at a boundary module",
      message:
        "#{primitive_msg} called inside a boundary module (controller / channel / " <>
          "LiveView / Oban worker / Plug). Atoms created from external input exhaust " <>
          "the BEAM atom table (~1M cap, no GC) — a remote DoS primitive.",
      why:
        "Boundary modules are where untrusted input arrives. Any atom created from " <>
          "that input lives forever. An attacker sending a stream of unique strings " <>
          "permanently consumes atom-table space; once exhausted, the node crashes " <>
          "and cannot recover until restart. This is one of the most reliable BEAM " <>
          "DoS vectors.",
      alternatives: [
        Fix.new(
          summary: "Use String.to_existing_atom/1 with an allowlist",
          detail:
            "If the input must already correspond to an atom your code knows about, " <>
              "use `String.to_existing_atom/1`. It raises on unknown input and creates " <>
              "no new atoms.",
          applies_when: "The set of valid atoms is finite and defined at compile time."
        ),
        Fix.new(
          summary: "Replace atom-keyed dispatch with string-keyed registry",
          detail:
            "Instead of converting to atom for dispatch, use " <>
              "`@actions %{\"name\" => &Mod.fun/n}` and `Map.fetch(@actions, name)`. " <>
              "Strings are GC'd; the registry is the security boundary.",
          applies_when:
            "The atom is used to dispatch a command, route an event, or pick a strategy."
        ),
        Fix.new(
          summary: "Keep the value as a string everywhere downstream",
          detail:
            "If the value just identifies something, a string works as well as an " <>
              "atom and avoids the atom-table risk entirely. Only convert to atom " <>
              "when you know the value matches a fixed compile-time set.",
          applies_when: "The atom is used as a key or label, not for process naming."
        )
      ],
      tags: [:security, :critical, :boundary],
      file: file,
      line: AST.line(meta)
    )
  end
end
