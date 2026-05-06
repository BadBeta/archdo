defmodule Archdo.Rules.OTP.GenServerCallNoExitCatch do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.60"

  @impl true
  def description,
    do:
      "GenServer.call(name, ...) to a registered name without try/catch :exit — " <>
        "down-server calls raise EXIT"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.flat_map(AST.find_all(ast, &gen_server_call_to_name?/1), fn call_node ->
      {{_, _, _}, meta, _} = call_node

      case under_try_catch_exit?(ast, meta) do
        true -> []
        false -> [build_diagnostic(file, AST.line(meta))]
      end
    end)
  end

  # `GenServer.call(name, msg, ...)` where `name` is an alias / atom
  # / via-tuple (i.e., a REGISTERED name). Pids skip — caller already
  # holds the pid and supervision handles liveness within their tree.
  defp gen_server_call_to_name?({{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, _, args})
       when is_list(args) and args != [] do
    case hd(args) do
      {:__aliases__, _, _} -> true
      atom when is_atom(atom) -> true
      {:via, _, _} -> true
      {{:., _, [_, _]}, _, _} -> true
      _ -> false
    end
  end

  defp gen_server_call_to_name?(_), do: false

  # Walk the whole AST. For each call site, find any `:try` ancestor
  # that has a `:catch` clause matching `:exit`. Cheap O(N²) but fine
  # for static analysis.
  defp under_try_catch_exit?(ast, target_meta) do
    target_line = AST.line(target_meta)

    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:try, try_meta, args} = node, _acc when is_list(args) ->
          case spans_line?(try_meta, args, target_line) and try_catches_exit?(args) do
            true -> {node, true}
            false -> {node, false}
          end

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp spans_line?(try_meta, args, target_line) do
    start_line = AST.line(try_meta)
    end_line = max_line(args, start_line)
    target_line >= start_line and target_line <= end_line
  end

  defp max_line(ast, default) do
    {_, max} =
      Macro.prewalk(ast, default, fn
        {_, meta, _} = node, acc ->
          {node, max(acc, AST.line(meta))}

        node, acc ->
          {node, acc}
      end)

    max
  end

  defp try_catches_exit?(args) do
    catch_clauses =
      Enum.find_value(args, [], fn
        kw when is_list(kw) -> Keyword.get(kw, :catch, [])
        _ -> nil
      end)

    Enum.any?(catch_clauses, &catch_clause_matches_exit?/1)
  end

  defp catch_clause_matches_exit?({:->, _, [[{:exit, _, _}], _]}), do: true
  defp catch_clause_matches_exit?({:->, _, [[:exit, _], _]}), do: true
  defp catch_clause_matches_exit?({:->, _, [[:exit | _], _]}), do: true
  defp catch_clause_matches_exit?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("5.60",
      title: "GenServer.call to registered name without try/catch :exit",
      message:
        "`GenServer.call(name, ...)` raises EXIT when the named process is down — wrap in " <>
          "`try ... catch :exit, _ -> ... end` if the caller should survive a down server.",
      why:
        "GenServer.call's failure mode for a down or missing process is `:exit` (NOT a " <>
          "regular exception). `rescue` doesn't catch it; only `catch :exit, _ ->` does. " <>
          "Code that needs to survive supervisor restarts of the callee, retries to a " <>
          "transient process, or external-process queries should bracket the call. Code " <>
          "running INSIDE the same supervision tree (where the callee's death == caller's " <>
          "death by design) doesn't need this — but the call to a NAMED process across " <>
          "trees is a different case.",
      alternatives: [
        Fix.new(
          summary: "Wrap in try/catch :exit",
          detail:
            "try do\n" <>
              "  {:ok, GenServer.call(MyApp.Worker, :status)}\n" <>
              "catch\n" <>
              "  :exit, _ -> {:error, :down}\n" <>
              "end",
          applies_when: "When the caller should survive the callee being down."
        ),
        Fix.new(
          summary: "Or check Process.whereis before the call (still races; use only as a probe)",
          detail:
            "case Process.whereis(MyApp.Worker) do\n" <>
              "  nil -> {:error, :not_running}\n" <>
              "  _pid -> GenServer.call(MyApp.Worker, :status)\n" <>
              "end",
          applies_when: "When you want a fast-path probe (race remains for crash mid-call)."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.4", "elixir-implementing/SKILL.md#7.4"],
      context: %{},
      file: file,
      line: line
    )
  end
end
