defmodule Archdo.Rules.Module.RegexInLoop do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.Helpers.LoopDetection

  @impl true
  def id, do: "6.49"

  @impl true
  def description,
    do: "Regex literal in hot path — recompiled each call, hoist to module attribute"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_regex_in_hot_paths(ast, file)
    end
  end

  defp find_regex_in_hot_paths(ast, file) do
    # Check all loop constructs (Enum, Stream, :lists, for, receive, recursion)
    loop_hits =
      Enum.map(LoopDetection.find_in_loops(ast, &regex_sigil?/1), fn {_, meta} ->
        build_diagnostic(file, AST.line(meta), :loop)
      end)

    # Check GenServer callbacks (hot paths)
    genserver_hits =
      Enum.map(LoopDetection.find_in_genserver_callbacks(ast, &regex_sigil?/1), fn {_, meta} ->
        build_diagnostic(file, AST.line(meta), :genserver_callback)
      end)

    # Check recursive functions
    recursion_hits =
      Enum.map(LoopDetection.find_in_recursive_fns(ast, &regex_sigil?/1), fn {_, meta} ->
        build_diagnostic(file, AST.line(meta), :recursion)
      end)

    loop_hits ++ genserver_hits ++ recursion_hits
  end

  defp regex_sigil?({:sigil_r, _, _}), do: true
  defp regex_sigil?({:sigil_R, _, _}), do: true
  defp regex_sigil?(_), do: false

  defp build_diagnostic(file, line, context) do
    location =
      case context do
        :loop -> "loop body"
        :genserver_callback -> "GenServer callback"
        :recursion -> "recursive function"
      end

    Diagnostic.info("6.49",
      title: "Regex literal in #{location}",
      message: "~r/.../ inside #{location} is recompiled on every invocation",
      why:
        "Regex sigils in module bodies and function heads are compiled once at compile time. " <>
          "However, inside function bodies (especially loops and callbacks), the regex " <>
          "may be recompiled each call. Hoist to a module attribute: " <>
          "`@my_pattern ~r/pattern/` to guarantee single compilation.",
      alternatives: [
        Fix.new(
          summary: "Hoist regex to a module attribute",
          detail:
            "Add `@my_pattern ~r/pattern/` at the top of the module, " <>
              "then reference `@my_pattern` in the function body.",
          applies_when: "Regex is used inside a loop, callback, or frequently-called function."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end
end
