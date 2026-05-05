defmodule Archdo.Rules.Module.TelemetryInRecursiveFunction do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "6.58"

  @impl true
  def description,
    do: "Telemetry call in recursive function — emits per iteration, perf overhead"

  @def_kws [:def, :defp, :defmacro, :defmacrop]

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      AST.has_marker?(ast, :archdo_intentional_recursive_telemetry) -> []
      true -> find_recursive_telemetry(file, ast)
    end
  end

  defp find_recursive_telemetry(file, ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {def_kw, meta, [head, kw]} = node, acc when def_kw in @def_kws and is_list(kw) ->
          {node, maybe_collect(meta, head, kw, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.map(hits, fn line -> build_diagnostic(file, line) end)
  end

  defp maybe_collect(meta, head, kw, acc) do
    case Unwrap.kw_get(kw, :do) do
      {:ok, body} -> maybe_flag(meta, head, body, acc)
      :error -> acc
    end
  end

  defp maybe_flag(meta, head, body, acc) do
    {fn_name, arity} = name_arity(head)

    case telemetry_recursive?(body, fn_name, arity) do
      true -> [AST.line(meta) | acc]
      false -> acc
    end
  end

  # `head` may be `{name, _, args}`, `{name, _, nil}`, or
  # `{:when, _, [inner_head, _guard]}`. Extract `{name, arity}`.
  defp name_arity({:when, _, [inner, _guard]}), do: name_arity(inner)
  defp name_arity({name, _, nil}) when is_atom(name), do: {name, 0}

  defp name_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp name_arity(_), do: {nil, 0}

  # Body has telemetry at TOP LEVEL (sibling of the recursive call,
  # not guarded by an if/case/cond) AND a self-call to fn_name/arity
  # somewhere inside.
  defp telemetry_recursive?(body, fn_name, arity) do
    top_level = top_level_exprs(body)
    has_top_level_telemetry?(top_level) and contains_self_call?(body, fn_name, arity)
  end

  defp top_level_exprs({:__block__, _, exprs}) when is_list(exprs), do: exprs
  defp top_level_exprs(single), do: [single]

  defp has_top_level_telemetry?(exprs) do
    Enum.any?(exprs, &telemetry_call?/1)
  end

  defp telemetry_call?({{:., _, [:telemetry, fun]}, _, args})
       when is_atom(fun) and is_list(args),
       do: fun in [:execute, :span]

  defp telemetry_call?(_), do: false

  defp contains_self_call?(body, fn_name, arity) do
    {_, found?} =
      Macro.prewalk(body, false, fn
        {^fn_name, _, args} = node, _acc when is_list(args) and length(args) == arity ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.58",
      title: "Telemetry call in recursive function",
      message:
        "`:telemetry.execute` / `:telemetry.span` is at the top level of a function " <>
          "that recurses — every iteration emits an event, which can dominate runtime " <>
          "for hot loops.",
      why:
        "Telemetry handlers run synchronously in the calling process. A naive emit-per- " <>
          "iteration in a tight loop can multiply runtime by orders of magnitude when " <>
          "handlers are non-trivial (logging, metrics export, etc.). The fix is to emit " <>
          "once per high-level operation, not per inner-loop step.",
      alternatives: [
        Fix.new(
          summary: "Wrap the recursion in :telemetry.span at the entry point",
          detail:
            "Move the telemetry to the public entry function, not the recursive helper:\n" <>
              "  def process(items), do: :telemetry.span([:my_app, :process], %{count: " <>
              "length(items)}, fn -> {do_loop(items, 0), %{}} end)",
          applies_when:
            "When the recursion is an internal implementation detail of a single user " <>
              "operation."
        ),
        Fix.new(
          summary: "Emit once per N iterations or only on entry",
          detail:
            "If per-iteration metrics are valuable, sample: `if rem(i, 1000) == 0 do " <>
              ":telemetry.execute(...) end` — at the cost of resolution.",
          applies_when: "When sampling is acceptable for the metric's purpose."
        ),
        Fix.new(
          summary: "Mark @archdo_intentional_recursive_telemetry",
          detail:
            "If per-iteration telemetry IS the goal (debug tracing, mandatory audit), " <>
              "set the marker at module level. Documents intent and silences this rule.",
          applies_when: "Per-iteration emission is the deliberate, justified design."
        )
      ],
      references: ["GUIDE.md#6.58"],
      context: %{},
      file: file,
      line: line
    )
  end
end
