defmodule Archdo.Rules.Testing.MocksNotVerified do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.13"

  @impl true
  def description, do: "Mox setups must call setup :verify_on_exit! to enforce expectations"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> check_mox_verification(file, ast)
    end
  end

  defp check_mox_verification(file, ast) do
    uses_mox =
      AST.contains?(ast, fn
        {{:., _, [{:__aliases__, _, [:Mox]}, func]}, _, _}
        when func in [:expect, :stub, :stub_with] ->
          true

        _ ->
          false
      end)

    has_verify =
      AST.contains?(ast, fn
        # setup :verify_on_exit!
        {:setup, _, [args]} when is_atom(args) -> args == :verify_on_exit!
        {:setup, _, [{:__block__, _, [:verify_on_exit!]}]} -> true
        # import Mox brings verify_on_exit! in scope
        {:import, _, [{:__aliases__, _, [:Mox]} | _]} -> true
        _ -> false
      end) and
        AST.contains?(ast, fn
          {:verify_on_exit!, _, _} -> true
          _ -> false
        end)

    if uses_mox and not has_verify do
      [
        Diagnostic.warning("7.13",
          title: "Mox expectations not verified on exit",
          message: "Test file uses Mox.expect/stub but does not call setup :verify_on_exit!",
          why:
            "Without `verify_on_exit!`, Mox doesn't enforce that the expectations actually fired. A test " <>
              "that says `expect(MockClient, :fetch, fn _ -> :ok end)` and never reaches the call still passes — " <>
              "you've documented an interaction the code never made and the test gives false confidence.",
          alternatives: [
            Fix.new(
              summary: "Add `setup :verify_on_exit!`",
              detail:
                "Add `import Mox` and `setup :verify_on_exit!` to the test module (or use a shared case " <>
                  "template that does it). Mox now fails any test where an expectation wasn't met.",
              example: """
              ```elixir
              import Mox
              setup :verify_on_exit!
              ```
              """,
              applies_when: "Always — there's no good reason to skip verification."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#7.13"],
          context: %{},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end
end
