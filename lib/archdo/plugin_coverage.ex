defmodule Archdo.PluginCoverage do
  @moduledoc false

  # §§ elixir-planning: §9.1 — runner pre-pass that scans every file
  # ONCE, builds a project-level index of which plug modules emit
  # telemetry / log calls, and threads the index through opts to every
  # per-file rule. CE-27 and CE-28 consume the index to exempt boundary
  # entry points whose observability is centralized one layer up.
  #
  # Plug shape: a module defining `def call(conn, _opts)`. Per-pipeline
  # scoping (matching `pipeline :api do plug X end` to controller
  # actions) is OUT OF SCOPE for v1: presence of any covering plug in
  # the project is signal enough that observability is plug-driven.

  alias Archdo.AST

  # The Plug.call/2 callback name — checked via `name == @plug_callback`
  # so the literal `:call` doesn't appear in a comparison RHS.
  @plug_callback :call

  @type t :: %{
          telemetry_plugs: [String.t()],
          log_plugs: [String.t()]
        }

  @doc """
  Scan a list of `{file, ast}` tuples for plug modules that emit
  telemetry or log calls. Returns the coverage index.
  """
  @spec scan([{String.t(), Macro.t()}]) :: t()
  def scan(file_asts) do
    {telemetry, log} =
      Enum.reduce(file_asts, {[], []}, fn {_file, ast}, acc ->
        absorb_classification(acc, classify_module(ast))
      end)

    %{
      telemetry_plugs: Enum.uniq(telemetry),
      log_plugs: Enum.uniq(log)
    }
  end

  defp absorb_classification(acc, :not_plug), do: acc

  defp absorb_classification({tele_acc, log_acc}, {:plug, module, kinds}) do
    {prepend_if(tele_acc, module, :telemetry in kinds),
     prepend_if(log_acc, module, :log in kinds)}
  end

  defp prepend_if(list, _module, false), do: list
  defp prepend_if(list, module, true), do: [module | list]

  # §§ elixir-implementing: §2.1 — multi-clause dispatch via case on a
  # tagged tuple keeps the reduce above flat. {:plug, name, kinds} when
  # the module IS a plug (carries discovered observability kinds);
  # :not_plug otherwise.
  defp classify_module(ast) do
    case plug_module?(ast) do
      false ->
        :not_plug

      true ->
        kinds =
          []
          |> add_if(AST.contains_telemetry?(ast), :telemetry)
          |> add_if(AST.contains_logger?(ast), :log)

        {:plug, AST.extract_module_name(ast), kinds}
    end
  end

  defp add_if(list, true, kind), do: [kind | list]
  defp add_if(list, false, _kind), do: list

  # A plug module defines `def call(conn, _opts)` — the Plug behaviour
  # callback. We don't require `@behaviour Plug` because many plug
  # modules omit it; the call/2 shape is the load-bearing signal.
  #
  # Path-specific plugs (`def call(%{request_path: "..."}, _)`) are
  # excluded — they run at endpoint level but only do work for matching
  # paths, so their Logger calls don't actually cover all requests.
  # Webhook plugs (Stripe, Tax-ID-Pro, etc.) follow this shape.
  defp plug_module?(ast) do
    call_clauses =
      ast
      |> AST.extract_functions(:public)
      |> Enum.filter(fn {name, arity, _, _, _} -> name == @plug_callback and arity == 2 end)

    case call_clauses do
      [] -> false
      clauses -> Enum.all?(clauses, &covering_plug_clause?/1)
    end
  end

  defp covering_plug_clause?({_name, _arity, _meta, args, _body}) do
    not path_specific_args?(args)
  end

  # The `call/2` first arg is the conn. A plug is path/condition-aware
  # (not blanket-covering) when the conn pattern matches on a routing
  # field — `request_path`, `path_info`, or `method`. Bare `conn`,
  # `%Conn{} = conn`, and `%Plug.Conn{}` (no field matches) are
  # blanket-covering.
  @discriminating_fields [:request_path, :path_info, :method]

  defp path_specific_args?([first | _]), do: discriminating_match?(first)
  defp path_specific_args?(_), do: false

  defp discriminating_match?({:=, _, [lhs, rhs]}) do
    discriminating_match?(lhs) or discriminating_match?(rhs)
  end

  # Bare map match: %{request_path: ...} or %{path_info: ...}.
  defp discriminating_match?({:%{}, _, fields}) when is_list(fields) do
    Enum.any?(fields, &discriminating_field?/1)
  end

  # Struct match: %Plug.Conn{request_path: ...}, %Conn{method: ...} —
  # AST shape is `{:%, _, [aliases, {:%{}, _, fields}]}`.
  defp discriminating_match?({:%, _, [_aliases, {:%{}, _, fields}]}) when is_list(fields) do
    Enum.any?(fields, &discriminating_field?/1)
  end

  defp discriminating_match?(_), do: false

  defp discriminating_field?({field, _}) when is_atom(field), do: field in @discriminating_fields

  defp discriminating_field?({{:__block__, _, [field]}, _}) when is_atom(field),
    do: field in @discriminating_fields

  defp discriminating_field?(_), do: false
end
