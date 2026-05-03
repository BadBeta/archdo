defmodule Archdo.Rules.Compiled.CrossBoundaryCall do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Config, Diagnostic, Fix}
  alias Archdo.Compiled

  @impl true
  def id, do: "1.21"

  @impl true
  def description, do: "Function call crosses context boundary — compiled ground-truth"

  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    calls = Compiled.calls(graph)
    modules = Compiled.modules(graph)
    config = Config.load()
    contexts = config.contexts

    case contexts do
      [] ->
        []

      _ ->
        project_modules = MapSet.new(Map.keys(modules))

        calls
        |> Enum.filter(fn call ->
          caller_mod = elem(call.caller, 0)
          callee_mod = elem(call.callee, 0)

          # Both must be project modules
          MapSet.member?(project_modules, caller_mod) and
            MapSet.member?(project_modules, callee_mod) and
            caller_mod != callee_mod and
            crosses_boundary?(caller_mod, callee_mod, contexts) and
            not boundary_module?(callee_mod, contexts)
        end)
        |> Enum.group_by(fn call ->
          {elem(call.caller, 0), elem(call.callee, 0)}
        end)
        |> Enum.map(fn {{caller_mod, callee_mod}, calls} ->
          build_diagnostic(caller_mod, callee_mod, calls, contexts)
        end)
    end
  end

  # A call crosses a boundary when the caller and callee are in different contexts,
  # AND the callee is not the context boundary module itself (calling the context
  # boundary is the correct pattern).
  defp crosses_boundary?(caller_mod, callee_mod, contexts) do
    caller_ctx = owning_context(caller_mod, contexts)
    callee_ctx = owning_context(callee_mod, contexts)

    caller_ctx != nil and callee_ctx != nil and caller_ctx != callee_ctx
  end

  # The context boundary module is the module with the same name as the context.
  # Calling it is correct — it's the public API.
  defp boundary_module?(module, contexts) do
    mod_str = AST.module_name(module)

    Enum.any?(contexts, fn ctx ->
      Archdo.AST.module_name(ctx) == mod_str
    end)
  end

  defp owning_context(module, contexts) do
    mod_str = AST.module_name(module)

    contexts
    |> Enum.filter(fn ctx ->
      ctx_str = Archdo.AST.module_name(ctx)
      mod_str == ctx_str or String.starts_with?(mod_str, ctx_str <> ".")
    end)
    |> Enum.max_by(fn ctx -> String.length(Archdo.AST.module_name(ctx)) end, fn -> nil end)
    |> case do
      nil -> nil
      ctx -> Archdo.AST.module_name(ctx)
    end
  end

  defp build_diagnostic(caller_mod, callee_mod, calls, contexts) do
    caller_name = AST.module_name(caller_mod)
    callee_name = AST.module_name(callee_mod)
    caller_ctx = owning_context(caller_mod, contexts) || "unknown"
    callee_ctx = owning_context(callee_mod, contexts) || "unknown"

    functions_called =
      calls
      |> Enum.map(fn call ->
        {f, a} = {elem(call.callee, 1), elem(call.callee, 2)}
        "#{f}/#{a}"
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join(", ")

    # Find the boundary module name for the callee context
    boundary_mod = callee_ctx

    Diagnostic.warning("1.21",
      title: "Cross-boundary call bypasses context API",
      message:
        "#{caller_name} (#{caller_ctx}) calls internal module #{callee_name} " <>
          "(#{callee_ctx}) directly: #{functions_called}",
      why:
        "Compiled analysis confirms #{caller_name} calls #{callee_name} directly, " <>
          "bypassing the #{callee_ctx} context boundary module. This creates tight " <>
          "coupling between contexts — changes to #{callee_name}'s internals can break " <>
          "#{caller_name}. After macro expansion, this is a ground-truth dependency, " <>
          "not an AST guess.",
      alternatives: [
        Fix.new(
          summary: "Call through the context boundary module",
          detail:
            "Replace direct calls to #{callee_name} with calls to #{boundary_mod}. " <>
              "The context module is the public API — internal modules should be hidden.",
          applies_when: "The called functionality should be part of the context's public API."
        ),
        Fix.new(
          summary: "Move the caller into the same context",
          detail:
            "If #{caller_name} is tightly coupled to #{callee_name}, it may belong " <>
              "in the #{callee_ctx} context rather than #{caller_ctx}.",
          applies_when: "The caller naturally belongs in the callee's domain."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.21"],
      context: %{
        caller: caller_name,
        callee: callee_name,
        caller_context: caller_ctx,
        callee_context: callee_ctx,
        functions: functions_called,
        call_count: length(calls)
      },
      file: "lib",
      line: 0
    )
  end
end
