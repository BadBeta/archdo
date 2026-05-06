defmodule Archdo.Rules.Module.NonLazyLoggerInspect do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.85"

  @impl true
  def description,
    do:
      ~s|`Logger.X("...\#{inspect(big)}...")` — non-lazy form runs `inspect` even when | <>
        ~s|the level is disabled; use `Logger.X(fn -> ... end)`|

  @logger_levels [:debug, :info, :warning, :warn, :error, :notice, :critical, :alert]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &non_lazy_logger_with_inspect?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # `Logger.X(arg, ...)` where:
  # - X is one of the level functions
  # - arg is a string-interpolation node (`{:<<>>, _, parts}`) that
  #   contains an `inspect/1,2` call somewhere in `parts`
  defp non_lazy_logger_with_inspect?({{:., _, [{:__aliases__, _, [:Logger]}, fun]}, _, [arg | _]})
       when fun in @logger_levels do
    interpolation_with_inspect?(arg)
  end

  defp non_lazy_logger_with_inspect?(_), do: false

  # String interpolation AST: `{:<<>>, _, parts}` where each part is
  # either a binary segment or `{:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, _]}`.
  # The `expr` may be `inspect(x)`.
  defp interpolation_with_inspect?({:<<>>, _, parts}) when is_list(parts) do
    {_, found?} =
      Macro.prewalk(parts, false, fn
        {:inspect, _, _} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp interpolation_with_inspect?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.85",
      title: "Logger interpolation with inspect — use the lazy fn form",
      message:
        "Logger call uses string interpolation that includes an `inspect/1` call. The " <>
          "non-lazy form evaluates the `inspect` even when the log level is disabled, " <>
          "wasting CPU on every call. Use `Logger.X(fn -> \"...\" end)` so the closure " <>
          "only runs when the level is enabled.",
      why:
        "`Logger.compare_levels` filtering happens AFTER the message is built unless you " <>
          "pass a closure. `inspect/1` on large structs can be very slow (recursive walk + " <>
          "string formatting). On hot paths the cost adds up; in production, debug-level " <>
          "logs are usually disabled but the inspect runs anyway.",
      alternatives: [
        Fix.new(
          summary: "Wrap in a closure",
          detail:
            "Logger.debug(fn -> \"worker state: \#{inspect(state)}\" end)\n" <>
              "# Closure body only runs if Logger's level threshold permits this call.",
          applies_when: "Always when interpolation includes inspect / heavy computation."
        ),
        Fix.new(
          summary: "Or pass structured metadata instead of stringifying",
          detail:
            "Logger.debug(\"worker state\", state: state)\n" <>
              "# Logger formatters and structured-log aggregators handle the value better\n" <>
              "# than a pre-stringified inspect output.",
          applies_when:
            "When the value is small / structured and your log backend supports metadata."
        )
      ],
      references: ["elixir-implementing/SKILL.md#8.7"],
      context: %{},
      file: file,
      line: line
    )
  end
end
