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
  defp plug_module?(ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.any?(fn {name, arity, _, _, _} -> name == @plug_callback and arity == 2 end)
  end

end
