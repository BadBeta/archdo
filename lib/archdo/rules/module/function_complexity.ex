defmodule Archdo.Rules.Module.FunctionComplexity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, CognitiveComplexity, Diagnostic, Fix}

  @max_arity 5
  # Private/internal recursive functions get a higher arity limit since
  # Erlang/OTP style uses accumulated state in recursive function args
  @max_arity_private 8
  @max_complexity 9
  @error_complexity 15

  # Flat-dispatch threshold mirrors CE-24's classifier — when a
  # function's cyclomatic count is dominated by independent dispatch
  # branches (each shallow), cognitive complexity stays low and the
  # cyclomatic number is misleading. CE-24 already flags this shape
  # as `flat_dispatch` informationally; 6.2 defers to it instead of
  # double-firing on the same function.
  @flat_dispatch_ratio 2

  @impl true
  def id, do: "6.2"

  @impl true
  def description, do: "Function complexity and arity limits"

  @impl true
  def analyze(file, ast, _opts) do
    is_internal = AST.internal_module?(ast)

    fns = AST.extract_functions(ast, :all)

    Enum.flat_map(fns, fn {name, arity, meta, _args, body} ->
      visibility = function_visibility(ast, name, arity)

      check_arity(file, name, arity, meta, visibility, is_internal) ++
        check_complexity(file, name, arity, meta, body)
    end)
  end

  defp check_arity(file, name, arity, meta, visibility, is_internal) do
    limit =
      if visibility == :private or is_internal do
        @max_arity_private
      else
        @max_arity
      end

    if arity > limit do
      [
        Diagnostic.info("6.2",
          title: "High function arity",
          message: "#{name}/#{arity} takes #{arity} arguments (limit: #{limit})",
          why:
            "Functions with many positional arguments are hard to call correctly: callers have to remember " <>
              "the order, type errors are silent (everything is `term`), and adding/removing/reordering args " <>
              "ripples to every call site. Grouping related parameters into a keyword list or struct gives " <>
              "named, optional, validatable inputs.",
          alternatives: [
            Fix.new(
              summary: "Group related parameters into a keyword list or options map",
              detail:
                "Replace `f(a, b, c, d, e, f)` with `f(opts)` where `opts` is a keyword list or map. Use " <>
                  "`Keyword.fetch!/2` and `Keyword.get/3` for required vs optional values. Callers see " <>
                  "named keys and the function can grow new options without breaking call sites.",
              applies_when: "Several arguments are configuration-like."
            ),
            Fix.new(
              summary: "Introduce a struct for the input",
              detail:
                "If the arguments describe a domain concept, create a struct (e.g. `MyApp.Filter`) with " <>
                  "`@enforce_keys` and a constructor. Functions take the struct as a single argument and " <>
                  "the validation lives in one place.",
              applies_when: "The arguments describe a coherent domain concept."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#6.2"],
          context: %{function: "#{name}/#{arity}", arity: arity, limit: limit},
          file: file,
          line: AST.line(meta)
        )
      ]
    else
      []
    end
  end

  defp check_complexity(file, name, arity, meta, body) do
    complexity = compute_complexity(body)

    cond do
      complexity > @error_complexity ->
        [complexity_diag(file, name, arity, meta, complexity, :very_high)]

      complexity > @max_complexity and not flat_dispatch?(body, complexity) ->
        [complexity_diag(file, name, arity, meta, complexity, :high)]

      true ->
        []
    end
  end

  # A function is "flat dispatch" when its cyclomatic count is high
  # but cognitive complexity stays low — i.e. many shallow clauses
  # rather than nested logic. This pattern is benign: each clause
  # is easy to read in isolation, the dispatch table itself is the
  # documentation, and refactoring rarely improves it. CE-24 already
  # surfaces these shapes informationally; firing 6.2 on top would
  # double-count the same function.
  defp flat_dispatch?(body, cyclo) do
    cogn = CognitiveComplexity.score(body)
    cyclo > cogn * @flat_dispatch_ratio
  end

  defp complexity_diag(file, name, arity, meta, complexity, kind) do
    Diagnostic.info("6.2",
      title: "High cyclomatic complexity",
      message:
        "#{name}/#{arity} has cyclomatic complexity #{complexity} (limit: #{@max_complexity})",
      why:
        "Cyclomatic complexity counts the number of independent paths through a function. High values mean " <>
          "many branches, deeply nested case/cond/with, and a corresponding multiplication of test cases. " <>
          "Functions above ~10 are hard to keep correct, hard to refactor, and are where bugs cluster. " <>
          "Splitting them into smaller, named pieces makes the logic and the tests linear.",
      alternatives: [
        Fix.new(
          summary: "Extract clauses into named helper functions",
          detail:
            "Each branch of a complex case/cond/with can usually become a small helper function with a " <>
              "descriptive name. The top-level function reads as a series of intent-revealing calls, and the " <>
              "helpers can be tested in isolation.",
          applies_when: "The branches each do meaningful work."
        ),
        Fix.new(
          summary: "Use multi-clause function definitions instead of one big case",
          detail:
            "Replace `case x do ...` with multiple `def fun(:foo, ...)`, `def fun(:bar, ...)` clauses. The " <>
              "complexity is distributed across clauses and the dispatch is done by pattern matching, which " <>
              "the compiler can optimize.",
          applies_when: "The complexity comes from a single big case dispatching on type/tag."
        ),
        Fix.new(
          summary: "Replace nested case/with chains with a `with` pipeline",
          detail:
            "If the branches are sequential `{:ok, _} | {:error, _}` checks, refactor into `with do` so the " <>
              "happy path is linear and the error cases collapse into a single `else` block.",
          applies_when: "The branches are sequential ok/error checks."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.2"],
      context: %{function: "#{name}/#{arity}", complexity: complexity, kind: kind},
      file: file,
      line: AST.line(meta)
    )
  end

  @doc """
  Compute cyclomatic complexity of an AST node.
  Counts decision points: case, cond, if, unless, with, and, or, &&, ||, rescue, catch.
  """
  def compute_complexity(nil), do: 1

  def compute_complexity(ast) do
    {_, count} =
      Macro.prewalk(ast, 1, fn
        {:case, _, _} = node, acc -> {node, acc + 1}
        {:cond, _, _} = node, acc -> {node, acc + 1}
        {:if, _, _} = node, acc -> {node, acc + 1}
        {:unless, _, _} = node, acc -> {node, acc + 1}
        {:with, _, _} = node, acc -> {node, acc + 1}
        {:and, _, _} = node, acc -> {node, acc + 1}
        {:or, _, _} = node, acc -> {node, acc + 1}
        {:&&, _, _} = node, acc -> {node, acc + 1}
        {:||, _, _} = node, acc -> {node, acc + 1}
        {:rescue, _} = node, acc -> {node, acc + 1}
        {:catch, _} = node, acc -> {node, acc + 1}
        # Count each -> clause in case/cond as a path
        {:->, _, _} = node, acc -> {node, acc + 1}
        node, acc -> {node, acc}
      end)

    count
  end

  defp function_visibility(ast, name, arity) do
    {_, vis} =
      Macro.prewalk(ast, :unknown, fn
        {:defp, _, [{^name, _, args} | _]} = node, _acc
        when is_list(args) and length(args) == arity ->
          {node, :private}

        {:def, _, [{^name, _, args} | _]} = node, _acc
        when is_list(args) and length(args) == arity ->
          {node, :public}

        node, acc ->
          {node, acc}
      end)

    vis
  end
end
