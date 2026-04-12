defmodule Archdo.Rules.Testing.MocksNeedBehaviours do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.3"

  @impl true
  def description, do: "Every Mox.defmock must reference a behaviour module"

  @impl true
  def analyze(file, ast, _opts) do
    find_defmock_calls(file, ast)
  end

  defp find_defmock_calls(file, ast) do
    AST.find_all(ast, fn
      # Mox.defmock(MockName, for: Module)
      {{:., _, [{:__aliases__, _, [:Mox]}, :defmock]}, _meta, _args} -> true
      _ -> false
    end)
    |> Enum.filter(fn {{:., _, _}, _, args} ->
      # Check that the `for:` option references a module
      # We can't check at AST time whether that module has @callback,
      # but we flag if `for:` is missing entirely
      case args do
        [_mock_name, opts] when is_list(opts) ->
          not Keyword.has_key?(opts, :for)

        _ ->
          true
      end
    end)
    |> Enum.map(fn {_, meta, _} ->
      Diagnostic.error("7.3",
        title: "Mox.defmock without `for:` option",
        message: "Mox.defmock is called without specifying a behaviour via `for:`",
        why:
          "Mox's main contract is verifying mocks: when you call `defmock(M, for: B)`, Mox checks that the " <>
            "mock implements every callback in B and that tests stub each call appropriately. Without `for:`, " <>
            "the mock has no contract — you can stub anything, including functions that don't exist on the real " <>
            "module, and tests pass against a completely fake API.",
        alternatives: [
          Fix.new(
            summary: "Add `for: BehaviourModule` to the defmock call",
            detail:
              "Identify the behaviour the mock represents and pass it via `for:`. Mox now verifies that the " <>
                "mock matches the contract and refuses to stub functions that aren't part of it.",
            example: """
            ```elixir
            Mox.defmock(MyApp.MockClient, for: MyApp.Client)
            ```
            """,
            applies_when: "Always — there's no good reason to skip the behaviour."
          ),
          Fix.new(
            summary: "Define a behaviour first if the target module doesn't have one",
            detail:
              "If you're mocking a concrete module that has no behaviour, extract one — declare a " <>
                "`@callback` for each function you stub and `@behaviour` it from the real implementation. " <>
                "Then pass that behaviour to defmock.",
            applies_when: "The target module has no behaviour yet."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.3"],
        context: %{},
        file: file,
        line: AST.line(meta)
      )
    end)
  end
end
