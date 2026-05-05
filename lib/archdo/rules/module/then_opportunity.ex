defmodule Archdo.Rules.Module.ThenOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.63"

  @impl true
  def description,
    do: "`(fn x -> ... end).()` in a pipeline — use `then/2` for clarity"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &pipe_into_immediate_fn?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # Pipeline RHS = `(fn ... end).()` — anonymous fn invoked immediately
  # against the piped value. Should be `then(&body/1)` instead.
  defp pipe_into_immediate_fn?({:|>, _, [_lhs, rhs]}), do: immediate_fn_call?(rhs)
  defp pipe_into_immediate_fn?(_), do: false

  defp immediate_fn_call?({{:., _, [{:fn, _, _}]}, _, _args}), do: true
  defp immediate_fn_call?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.63",
      title: "`(fn ... end).()` in pipeline — use `then/2`",
      message:
        "Pipeline applies an anonymous function via `(fn x -> ... end).()`. The idiomatic " <>
          "form is `|> then(&body(&1))` — clearer that this is a single transformation step.",
      why:
        "`Kernel.then/2` was added specifically for this case: applying a non-first-arg-" <>
          "compatible function to the piped value. The `(fn ... end).()` form predates " <>
          "`then/2` and tends to be reached for from C-style closure-application habit. " <>
          "`then/2` reads as 'now do this with the value' and matches the rest of the " <>
          "pipeline's visual rhythm.",
      alternatives: [
        Fix.new(
          summary: "Replace with `|> then(&...)`",
          detail: "data\n|> normalize()\n|> then(&compute(&1, extra))",
          applies_when: "When the anonymous function takes one argument and applies it directly."
        )
      ],
      references: ["elixir-implementing/SKILL.md#5.1", "elixir-implementing/SKILL.md#2.10"],
      context: %{},
      file: file,
      line: line
    )
  end
end
