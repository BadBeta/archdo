defmodule Archdo.Rules.Module.CodeEvalStringOrQuoted do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.93"

  @impl true
  def description,
    do:
      "`Code.eval_string` / `Code.eval_quoted` in production code — runs " <>
        "ARBITRARY Elixir; near-always wrong outside Mix tasks and tests"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) or mix_task_path?(file) do
      true -> []
      false -> find_calls(file, ast)
    end
  end

  defp mix_task_path?(file) do
    file =~ "lib/mix/tasks/" or file =~ ~r{^mix/tasks/}
  end

  defp find_calls(file, ast) do
    ast
    |> AST.find_all(&code_eval_call?/1)
    |> Enum.map(fn node -> build_diagnostic(file, line_of(node), name_of(node)) end)
  end

  defp code_eval_call?({{:., _, [{:__aliases__, _, [:Code]}, fun]}, _, _})
       when fun in [:eval_string, :eval_quoted, :eval_file],
       do: true

  defp code_eval_call?(_), do: false

  defp line_of({_, meta, _}), do: AST.line(meta)

  defp name_of({{:., _, [{:__aliases__, _, [:Code]}, fun]}, _, _}), do: "Code.#{fun}"
  defp name_of(_), do: "Code.eval"

  defp build_diagnostic(file, line, call) do
    Diagnostic.warning("6.93",
      title: "`#{call}` — runs arbitrary Elixir; remove or sandbox",
      message:
        "`#{call}` evaluates an Elixir source string (or quoted form) AT RUNTIME " <>
          "with full access to the BEAM. If the input ever comes from user data, " <>
          "an HTTP body, a database row written by a less-trusted writer, or a file " <>
          "loaded by name, this is remote code execution.",
      why:
        "Even on \"trusted\" input, `Code.eval_*` reaches escape velocity quickly: " <>
          "an admin field someone forgot to sanitize, a config value loaded from a " <>
          "vendor's response, a debug helper that someone left enabled in prod. The " <>
          "library exists for legitimate compile-time / build-time tooling (Mix " <>
          "tasks, code generators, IEx). In production application code paths, the " <>
          "answer is almost always: parse the input into a domain-specific AST and " <>
          "evaluate it explicitly with a safe interpreter, OR don't accept code at " <>
          "all — accept data instead.",
      alternatives: [
        Fix.new(
          summary: "Replace with a safe interpreter for a domain-specific language",
          detail:
            "# BAD — eval arbitrary Elixir from a config string\n" <>
              "{rule, _} = Code.eval_string(user_provided_rule)\n\n" <>
              "# GOOD — define a small AST you control, parse, then interpret\n" <>
              "defmodule MyApp.Rule do\n" <>
              "  def parse(str), do: # ... NimbleParsec / handcrafted parser\n" <>
              "  def evaluate(%Rule{op: :eq, lhs: l, rhs: r}, ctx), do: lookup(l, ctx) == r\n" <>
              "  def evaluate(%Rule{op: :and, parts: ps}, ctx), do: Enum.all?(ps, &evaluate(&1, ctx))\nend",
          applies_when: "When you need user-defined rules, formulas, or expressions."
        ),
        Fix.new(
          summary: "Or: this is build-time tooling — move it to a Mix task",
          detail:
            "If the eval is genuinely build/dev-only (codegen, scaffold, " <>
              "REPL helper), put it under `lib/mix/tasks/` — those paths are " <>
              "exempt from this rule.",
          applies_when: "When the call legitimately runs only at build time."
        )
      ],
      references: [
        "elixir-reviewing/security-audit-deep.md",
        "elixir-reviewing/SKILL.md#7.8"
      ],
      context: %{call: call},
      file: file,
      line: line
    )
  end
end
