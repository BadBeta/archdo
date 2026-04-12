defmodule Archdo.Rules.Testing.AsyncEligibility do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.4"

  @impl true
  def description, do: "Test files should declare async: true when eligible"

  @impl true
  def analyze(file, ast, _opts) do
    if not AST.test_file?(file) do
      []
    else
      check_async_eligibility(file, ast)
    end
  end

  defp check_async_eligibility(file, ast) do
    use_clauses = find_use_clauses(ast)
    has_async = Enum.any?(use_clauses, fn {_meta, opts} -> async_true?(opts) end)
    has_explicit_false = Enum.any?(use_clauses, fn {_meta, opts} -> async_false?(opts) end)
    blockers = find_async_blockers(ast)

    cond do
      has_async ->
        []

      has_explicit_false ->
        # User opted out explicitly, respect it
        []

      use_clauses == [] ->
        []

      blockers != [] ->
        []

      true ->
        [{meta, _} | _] = use_clauses

        [
          Diagnostic.info("7.4",
            title: "Test file not running async",
            message: "Test file does not pass `async: true` and has no obvious blockers",
            why:
              "ExUnit runs async-marked test files in parallel, which can dramatically reduce suite time. " <>
                "Tests that don't share global state (no Application.put_env, no named ETS tables, no shared " <>
                "side effects) are eligible. Leaving them sync slows down CI for no reason and the slower the " <>
                "suite is, the less often developers run it.",
            alternatives: [
              Fix.new(
                summary: "Add `async: true` to the use ExUnit.Case line",
                detail:
                  "Change `use ExUnit.Case` to `use ExUnit.Case, async: true`. Run the suite once to confirm " <>
                    "no flakiness, then commit.",
                applies_when: "The test really has no shared state — the rule already checked for blockers."
              ),
              Fix.new(
                summary: "Explicitly opt out with `async: false` if you have a hidden blocker",
                detail:
                  "If you know the test has a blocker the rule didn't detect (process registration, shared " <>
                    "test fixtures, etc.), add `async: false` explicitly. The rule respects an explicit opt-out " <>
                    "and stops nagging.",
                applies_when: "The test has hidden state that prevents parallelism."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#7.4"],
            context: %{},
            file: file,
            line: AST.line(meta)
          )
        ]
    end
  end

  defp find_use_clauses(ast) do
    AST.find_all(ast, fn
      {:use, _meta, [{:__aliases__, _, aliases} | _]} ->
        last = List.last(aliases) |> Atom.to_string()

        last in ["Case", "CaseTemplate"] or
          String.ends_with?(last, "Case") or
          String.ends_with?(last, "DataCase")

      _ ->
        false
    end)
    |> Enum.map(fn {:use, meta, args} ->
      opts =
        case args do
          [_] -> []
          [_, opts] when is_list(opts) -> opts
          [_, {:__block__, _, [opts]}] when is_list(opts) -> opts
          _ -> []
        end

      {meta, opts}
    end)
  end

  defp async_true?(opts) do
    case Keyword.get(opts, :async) do
      true -> true
      {:__block__, _, [true]} -> true
      _ -> false
    end
  end

  defp async_false?(opts) do
    case Keyword.get(opts, :async) do
      false -> true
      {:__block__, _, [false]} -> true
      _ -> false
    end
  end

  defp find_async_blockers(ast) do
    AST.find_all(ast, fn
      # Application.put_env — global state mutation
      {{:., _, [{:__aliases__, _, [:Application]}, :put_env]}, _, _} -> true
      # :ets.new with named_table or :public — likely global
      {{:., _, [:ets, :new]}, _, _} -> true
      # File system mutation outside tmp
      {{:., _, [{:__aliases__, _, [:File]}, func]}, _, _} when func in [:write, :write!, :rm, :rm_rf] -> true
      # Named GenServer/Agent.start_link with name: __MODULE__ at top level
      _ -> false
    end)
  end

end
