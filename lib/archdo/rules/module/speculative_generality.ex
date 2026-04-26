defmodule Archdo.Rules.Module.SpeculativeGenerality do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.10"

  @impl true
  def description, do: "Behaviours with no implementations or only mock implementations"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: walk all files, find behaviour declarations and @behaviour usages,
  flag behaviours with zero or only-test implementations.
  """
  def analyze_project(file_asts) do
    {behaviours, implementations} =
      Enum.reduce(file_asts, {%{}, %{}}, fn {file, ast}, {behaviours, impls} ->
        {file_behaviours, file_impls} = scan_file(file, ast)
        {Map.merge(behaviours, file_behaviours), merge_impls(impls, file_impls)}
      end)

    Enum.flat_map(behaviours, fn {bhv, def_info} ->
      impl_files = Map.get(implementations, bhv, [])
      check_behaviour(bhv, def_info, impl_files)
    end)
  end

  defp scan_file(file, ast) do
    behaviours =
      case AST.find_all(ast, fn
             {:@, _, [{:callback, _, _}]} -> true
             _ -> false
           end) do
        [] ->
          %{}

        _list ->
          name = AST.extract_module_name(ast)
          line = find_module_line(ast)
          %{name => %{file: file, line: line}}
      end

    impls =
      AST.find_all(ast, fn
        {:@, _, [{:behaviour, _, _}]} -> true
        _ -> false
      end)
      |> Enum.flat_map(fn
        {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]} ->
          bhv_name = AST.module_name(Module.concat(parts))
          [{bhv_name, file}]

        # @behaviour :erlang_atom (Erlang behaviours like :gen_server, :ranch_protocol)
        {:@, _, [{:behaviour, _, [atom]}]} when is_atom(atom) ->
          [{Atom.to_string(atom), file}]

        # Wrapped by literal_encoder
        {:@, _, [{:behaviour, _, [{:__block__, _, [atom]}]}]} when is_atom(atom) ->
          [{Atom.to_string(atom), file}]

        _ ->
          []
      end)
      |> Enum.into(%{}, fn {bhv, file} -> {bhv, [file]} end)

    {behaviours, impls}
  end

  defp merge_impls(impls, new) do
    Map.merge(impls, new, fn _k, l1, l2 -> l1 ++ l2 end)
  end

  defp check_behaviour(bhv, def_info, impl_files) do
    cond do
      impl_files == [] ->
        [
          Diagnostic.info("4.10",
            title: "Behaviour with no implementations",
            message: "Behaviour #{bhv} has no @behaviour implementations in this project",
            why:
              "A behaviour without implementations is speculative generality — an abstraction added in " <>
                "anticipation of variants that never arrived. The cost is real (callers go through dispatch, " <>
                "readers chase the impl) but the benefit (multiple implementations) is hypothetical. Either " <>
                "the implementation lives elsewhere and the rule missed it, or the abstraction was premature.",
            alternatives: [
              Fix.new(
                summary: "Inline the would-be implementation as plain functions",
                detail:
                  "Replace the behaviour with a regular module containing the operations. If a second " <>
                    "implementation appears later, reintroduce the behaviour then — it's a small refactor.",
                applies_when:
                  "The abstraction was added 'just in case' and no second implementation is planned."
              ),
              Fix.new(
                summary: "Verify the implementation isn't outside the analyzed paths",
                detail:
                  "If the behaviour really is implemented (e.g. in a sibling app or in test/support that " <>
                    "isn't being analyzed), make sure those paths are included in the archdo run.",
                applies_when: "The implementation lives in a directory not in the scan."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#4.10"],
            context: %{behaviour: bhv, kind: :no_impls},
            file: def_info.file,
            line: def_info.line
          )
        ]

      Enum.all?(impl_files, &test_or_mock_file?/1) ->
        [
          Diagnostic.info("4.10",
            title: "Behaviour only implemented by tests/mocks",
            message: "Behaviour #{bhv} has only test/mock implementations — no production usage",
            why:
              "A behaviour that only exists for mock-driven tests is the wrong tool: the production code path " <>
                "uses one concrete implementation (so the abstraction adds nothing) and tests use Mox (which " <>
                "would work fine on the concrete module via a real seam). The behaviour is dead weight.",
            alternatives: [
              Fix.new(
                summary:
                  "Inline the production implementation and use Mox-style verifying mocks differently",
                detail:
                  "If you only need to mock the module in tests, declare the test mock as a separate module that " <>
                    "the test passes in (dependency injection via function arg or Application env), and remove " <>
                    "the behaviour ceremony.",
                applies_when: "The behaviour exists purely for tests."
              ),
              Fix.new(
                summary: "Document why the behaviour is intentional",
                detail:
                  "If you've decided the behaviour-as-test-seam pattern is the right tradeoff, add a moduledoc " <>
                    "explaining the choice and add to the freeze baseline so the rule stops nagging.",
                applies_when: "You've consciously chosen this pattern."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#4.10"],
            context: %{behaviour: bhv, kind: :test_only},
            file: def_info.file,
            line: def_info.line
          )
        ]

      true ->
        []
    end
  end

  defp test_or_mock_file?(file) do
    AST.test_file?(file) or
      String.contains?(file, "mock") or
      String.contains?(file, "Mock")
  end

  defp find_module_line(ast) do
    {_, line} =
      Macro.prewalk(ast, 1, fn
        {:defmodule, meta, _} = node, _acc -> {node, AST.line(meta)}
        node, acc -> {node, acc}
      end)

    line
  end
end
