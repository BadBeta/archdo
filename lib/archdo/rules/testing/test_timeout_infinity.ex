defmodule Archdo.Rules.Testing.TestTimeoutInfinity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "7.34"

  @impl true
  def description,
    do:
      "`@tag timeout: :infinity` / `@moduletag timeout: :infinity` — a hung " <>
        "test hangs CI; use a real ms timeout sized to the test"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    ast
    |> AST.find_all(&infinity_tag?/1)
    |> Enum.map(fn {_, meta, _} -> build_diagnostic(file, AST.line(meta)) end)
  end

  # `@tag timeout: :infinity` parses as `{:@, _, [{:tag, _, [[timeout: :infinity]]}]}`
  defp infinity_tag?({:@, _, [{name, _, [arg]}]}) when name in [:tag, :moduletag] do
    timeout_infinity?(arg)
  end

  defp infinity_tag?(_), do: false

  defp timeout_infinity?(opts) when is_list(opts) do
    case Unwrap.kw_get(opts, :timeout) do
      {:ok, :infinity} -> true
      _ -> false
    end
  end

  defp timeout_infinity?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("7.34",
      title: "`timeout: :infinity` on test — a hung test hangs CI",
      message:
        "This `@tag` / `@moduletag` sets the test timeout to `:infinity`. If the " <>
          "test hangs (deadlock, race, slow external dep), CI runs forever and " <>
          "the failure is invisible until the build worker is recycled by the CI " <>
          "system. Always set a real millisecond timeout sized to the test's " <>
          "expected runtime — at most a few minutes for the slowest case.",
      why:
        "ExUnit's default test timeout is 60_000 ms (1 minute) — that's already " <>
          "generous. Tests that genuinely need more should ask for an explicit " <>
          "value (`@tag timeout: 300_000` for a 5-minute integration test). " <>
          "`:infinity` is never the right answer: if the test is slow, that's a " <>
          "fact about the test that operators need to know; if it's hanging, " <>
          "that's a bug to surface. To debug a suspected hang, use " <>
          "`Process.flag(:trap_exit, true)` and capture the stuck stack trace.",
      alternatives: [
        Fix.new(
          summary: "Set a real timeout sized to the test",
          detail:
            "@tag timeout: 60_000      # 1 minute — typical slow integration test\n" <>
              "@tag timeout: 300_000     # 5 minutes — full-suite end-to-end\n\n" <>
              "# At the module level for ALL tests in the file:\n" <>
              "@moduletag timeout: 120_000",
          applies_when: "Always — every test must have a finite timeout."
        )
      ],
      references: ["elixir-implementing/testing-patterns.md"],
      context: %{},
      file: file,
      line: line
    )
  end
end
