defmodule Archdo.Rules.Testing.MockingOwnModules do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.15"

  @impl true
  def description, do: "Mock at system boundaries only — don't mock modules you own"

  @impl true
  def analyze(file, ast, _opts) do
    if not AST.test_file?(file) and not support_file?(file) do
      []
    else
      find_own_module_mocks(file, ast)
    end
  end

  defp find_own_module_mocks(file, ast) do
    # Determine the app's root namespace from the mock target module
    AST.find_all(ast, fn
      # Mox.defmock(MyApp.Users.Mock, for: MyApp.Users)
      {{:., _, [{:__aliases__, _, [:Mox]}, :defmock]}, _, _} -> true
      {:defmock, _, _} -> true
      _ -> false
    end)
    |> Enum.flat_map(&extract_mock_target/1)
    |> Enum.filter(&own_module?/1)
    |> Enum.map(fn {target, meta} ->
      Diagnostic.info("7.15",
        title: "Mocking an internal module",
        message: "Mox.defmock targets #{target}, which appears to be an internal (non-boundary) module",
        why:
          "Mocks at system boundaries (HTTP, email, external APIs) shield tests from slow/flaky network. " <>
            "Mocking your own internal modules instead of using the real implementation tests the test, not " <>
            "the code: a refactor of the real module that breaks behaviour will leave the test green because " <>
            "the test is checking against a stub of the old behaviour.",
        alternatives: [
          Fix.new(
            summary: "Use the real implementation in the test",
            detail:
              "Internal modules are usually fast and pure enough to call directly. Set up the inputs, call " <>
                "the real function, and assert on the actual output. The test verifies real behaviour.",
            applies_when: "The internal module is fast and doesn't have hidden side effects."
          ),
          Fix.new(
            summary: "Extract a behaviour at the actual boundary and mock that instead",
            detail:
              "If the reason for mocking is that the internal module makes a side-effecting call, push the " <>
                "side effect to the boundary (an adapter), define a behaviour there, and mock the boundary. " <>
                "The internal logic stays real and tested.",
            applies_when: "The internal module touches a side-effecting dependency."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.15"],
        context: %{target: target},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp extract_mock_target({{:., _, [_, :defmock]}, meta, args}), do: extract_from_args(args, meta)
  defp extract_mock_target({:defmock, meta, args}), do: extract_from_args(args, meta)

  defp extract_from_args([_mock_name, opts], meta) when is_list(opts) do
    case Keyword.get(opts, :for) do
      {:__aliases__, _, parts} ->
        [{format_module(parts), meta}]

      _ ->
        []
    end
  end

  defp extract_from_args(_, _), do: []

  defp format_module(parts) do
    parts |> Module.concat() |> Atom.to_string() |> String.replace_leading("Elixir.", "")
  end

  # Heuristic: a module is "own" if its top namespace is the app prefix and
  # it's NOT in an adapter/client/infrastructure/boundary namespace.
  defp own_module?({name, _meta}) do
    parts = String.split(name, ".")

    case parts do
      [_top | rest] when rest != [] ->
        path_lower = Enum.map_join(rest, "/", &String.downcase/1)

        not String.contains?(path_lower, "adapter") and
          not String.contains?(path_lower, "client") and
          not String.contains?(path_lower, "mailer") and
          not String.contains?(path_lower, "infrastructure") and
          not String.contains?(path_lower, "http") and
          not String.contains?(path_lower, "gateway") and
          not String.contains?(path_lower, "boundary")

      _ ->
        false
    end
  end

  defp support_file?(file), do: String.contains?(file, "/test/support/")
end
