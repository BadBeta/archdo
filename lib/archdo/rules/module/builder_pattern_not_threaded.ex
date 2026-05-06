defmodule Archdo.Rules.Module.BuilderPatternNotThreaded do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.101"

  @impl true
  def description, do: "Builder-pattern rebind chain — should be a pipeline"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_builder_rebind_chains(file, ast)
    end
  end

  defp find_builder_rebind_chains(file, ast) do
    ast
    |> AST.find_all(&block_node?/1)
    |> Enum.flat_map(&maybe_flag_block(&1, file))
  end

  defp block_node?({:__block__, _, stmts}) when is_list(stmts), do: true
  defp block_node?(_), do: false

  defp maybe_flag_block({:__block__, _meta, stmts}, file) do
    stmts
    |> longest_self_threading_run()
    |> case do
      {var, count, line} when count >= 3 -> [build_diagnostic(file, line, var, count)]
      _ -> []
    end
  end

  defp maybe_flag_block(_, _), do: []

  # Find the longest run of consecutive `var = call(var, ...)` statements
  # with the SAME var. Returns `{var_name, count}` or `nil`.
  defp longest_self_threading_run(stmts) do
    {_cur_var, _cur_count, _cur_line, best_var, best_count, best_line} =
      Enum.reduce(stmts, {nil, 0, 0, nil, 0, 0}, &fold_run/2)

    case best_var do
      nil -> nil
      _ -> {best_var, best_count, best_line}
    end
  end

  # Acc: {cur_var, cur_count, cur_line, best_var, best_count, best_line}
  # cur_line tracks the FIRST rebind in the current run (so the diagnostic
  # points at where the chain starts).
  defp fold_run(stmt, {cur_var, cur_count, cur_line, best_var, best_count, best_line}) do
    case rebind_self_threading_var(stmt) do
      {:ok, ^cur_var, _line} when not is_nil(cur_var) ->
        new_count = cur_count + 1
        update_acc(cur_var, new_count, cur_line, best_var, best_count, best_line)

      {:ok, var, line} ->
        update_acc(var, 1, line, best_var, best_count, best_line)

      :no ->
        {nil, 0, 0, best_var, best_count, best_line}
    end
  end

  defp update_acc(var, count, line, _best_var, best_count, _best_line)
       when count > best_count,
       do: {var, count, line, var, count, line}

  defp update_acc(var, count, line, best_var, best_count, best_line),
    do: {var, count, line, best_var, best_count, best_line}

  # `var = mod.fun(var, ...)` or `var = fun(var, ...)` — return `{:ok, var, line}`.
  defp rebind_self_threading_var({:=, meta, [{var, _, ctx}, rhs]})
       when is_atom(var) and is_atom(ctx) do
    case rhs_first_arg(rhs) do
      {:ok, ^var} -> {:ok, var, AST.line(meta)}
      _ -> :no
    end
  end

  defp rebind_self_threading_var(_), do: :no

  # Extract the first arg of an RHS call. Handles bare fn calls and
  # remote (mod.fun) calls.
  defp rhs_first_arg({{:., _, [_mod, _fun]}, _, [{first, _, ctx} | _]})
       when is_atom(first) and is_atom(ctx),
       do: {:ok, first}

  defp rhs_first_arg({fun, _, [{first, _, ctx} | _]})
       when is_atom(fun) and is_atom(first) and is_atom(ctx),
       do: {:ok, first}

  defp rhs_first_arg(_), do: :no

  defp build_diagnostic(file, line, var, count) do
    Diagnostic.info("6.101",
      title: "Builder-pattern rebind chain — pipe instead",
      message:
        "#{count} consecutive `#{var} = call(#{var}, ...)` rebindings — " <>
          "thread `#{var}` through a pipeline instead.",
      why:
        "When a value flows through several builder calls (`Ecto.Multi`, " <>
          "`Plug.Conn`, `Phoenix.LiveView.Socket`, `Ecto.Changeset`), the " <>
          "pipe operator threads it implicitly. The rebind form (`x = ...; " <>
          "x = ...; x = ...`) is just imperative-flavored — it forces the " <>
          "reader to verify each line refers to the previous binding. The " <>
          "pipeline says 'same subject, multiple steps' once at the top.",
      alternatives: [
        Fix.new(
          summary: "Thread with pipes",
          detail: "Replace each `x = mod.fun(x, args)` with `|> mod.fun(args)`.",
          example: """
          ```elixir
          # before
          multi = Ecto.Multi.new()
          multi = Ecto.Multi.insert(multi, :user, ...)
          multi = Ecto.Multi.update(multi, :profile, ...)
          multi = Ecto.Multi.run(multi, :notify, fn _, _ -> ... end)

          # after
          Ecto.Multi.new()
          |> Ecto.Multi.insert(:user, ...)
          |> Ecto.Multi.update(:profile, ...)
          |> Ecto.Multi.run(:notify, fn _, _ -> ... end)
          ```
          """,
          applies_when:
            "Each step's first arg is the same builder; no intermediate computation interrupts the chain."
        )
      ],
      file: file,
      line: line
    )
  end
end
