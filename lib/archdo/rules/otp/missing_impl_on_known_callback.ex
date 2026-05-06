defmodule Archdo.Rules.OTP.MissingImplOnKnownCallback do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "5.61"

  @impl true
  def description,
    do:
      "Behaviour callback `def` lacks `@impl true` — compiler can't catch typos / removed callbacks"

  # Map: behaviour module aliases (matched by tail) → set of callback
  # name atoms whose presence in this module strongly implies callback
  # implementation.
  @callback_table %{
    [:GenServer] =>
      MapSet.new([
        :init,
        :handle_call,
        :handle_cast,
        :handle_info,
        :handle_continue,
        :terminate,
        :code_change,
        :format_status
      ]),
    [:Supervisor] => MapSet.new([:init]),
    [:DynamicSupervisor] => MapSet.new([:init]),
    [:Plug] => MapSet.new([:init, :call]),
    [:Plug, :Builder] => MapSet.new([:init, :call]),
    [:Phoenix, :LiveView] =>
      MapSet.new([
        :mount,
        :handle_params,
        :handle_event,
        :handle_info,
        :render,
        :terminate,
        :handle_async,
        :handle_call,
        :handle_cast
      ]),
    [:Oban, :Worker] => MapSet.new([:perform, :timeout, :backoff])
  }

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    case behaviours_used(ast) do
      empty when empty == %{} ->
        []

      callbacks ->
        scan_module_for_missing_impl(ast, callbacks, file)
    end
  end

  # Returns a MapSet of callback names that this module is expected to
  # implement, based on the union of all `use Behaviour` and
  # `@behaviour` declarations.
  defp behaviours_used(ast) do
    {_, expected} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:use, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, MapSet.union(acc, callbacks_for(parts))}

        {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]} = node, acc ->
          {node, MapSet.union(acc, callbacks_for(parts))}

        node, acc ->
          {node, acc}
      end)

    case MapSet.size(expected) do
      0 -> %{}
      _ -> %{callbacks: expected}
    end
  end

  defp callbacks_for(parts) when is_list(parts) do
    Map.get(@callback_table, parts) || Map.get(@callback_table, [List.last(parts)]) ||
      MapSet.new()
  end

  defp callbacks_for(_), do: MapSet.new()

  # For each module body, walk the statement sequence. Track whether
  # the most recent attribute statement is `@impl ...`. When a `def`
  # appears with a callback name and the @impl flag is NOT set, fire.
  defp scan_module_for_missing_impl(ast, %{callbacks: expected}, file) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [_alias, kw]} = node, acc when is_list(kw) ->
          case Unwrap.kw_get(kw, :do) do
            {:ok, body} -> {node, scan_block(block_stmts(body), expected) ++ acc}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.map(hits, fn {line, name, arity} -> build_diagnostic(file, line, name, arity) end)
  end

  defp block_stmts({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp block_stmts(single), do: [single]

  defp scan_block(stmts, expected) do
    {hits, _state} =
      Enum.reduce(stmts, {[], :no_impl}, &reduce_stmt(&1, &2, expected))

    hits
  end

  defp reduce_stmt(stmt, {acc, impl_state}, expected) do
    case classify(stmt) do
      :impl -> {acc, :impl}
      {:def, name, arity, line} -> dispatch_def(name, arity, line, acc, impl_state, expected)
      :other -> {acc, impl_state}
    end
  end

  defp dispatch_def(name, arity, line, acc, :no_impl, expected) do
    case MapSet.member?(expected, name) do
      true -> {[{line, name, arity} | acc], :no_impl}
      false -> {acc, :no_impl}
    end
  end

  defp dispatch_def(_name, _arity, _line, acc, _impl_state, _expected),
    do: {acc, :no_impl}

  defp classify({:@, _, [{:impl, _, _}]}), do: :impl

  defp classify({:def, meta, [head | _]}) do
    case head do
      {:when, _, [{name, _, args} | _]} when is_atom(name) and is_list(args) ->
        {:def, name, length(args), AST.line(meta)}

      {name, _, args} when is_atom(name) and is_list(args) ->
        {:def, name, length(args), AST.line(meta)}

      {name, _, nil} when is_atom(name) ->
        {:def, name, 0, AST.line(meta)}

      _ ->
        :other
    end
  end

  defp classify(_), do: :other

  defp build_diagnostic(file, line, name, arity) do
    Diagnostic.warning("5.61",
      title: "Behaviour callback `#{name}/#{arity}` missing `@impl true`",
      message:
        "This module declares a behaviour (GenServer / Supervisor / Plug / LiveView / " <>
          "Oban.Worker) and defines `#{name}/#{arity}` — a callback name. Add `@impl true` " <>
          "(or `@impl Module`) above the def so the compiler verifies the implementation.",
      why:
        "`@impl true` is the compiler's check for behaviour-implementation correctness. It " <>
          "warns on typos (`hanle_call` vs `handle_call`), missing callbacks, and arity " <>
          "mismatches. Without it, a typo silently becomes a regular helper and the " <>
          "framework never calls it — discovered only at runtime when the missing callback " <>
          "would have been invoked.",
      alternatives: [
        Fix.new(
          summary: "Add `@impl true` above the def",
          detail:
            "@impl true\n" <>
              "def init(state), do: {:ok, state}",
          applies_when: "Always for behaviour callbacks."
        ),
        Fix.new(
          summary:
            "Or `@impl SomeBehaviour` when multiple behaviours are used and you want to disambiguate",
          detail: "@impl GenServer\ndef init(state), do: {:ok, state}",
          applies_when:
            "When the module implements multiple behaviours and the callback name is " <>
              "ambiguous between them."
        )
      ],
      references: ["elixir-implementing/SKILL.md#1", "elixir-implementing/SKILL.md#9.6"],
      context: %{callback: "#{name}/#{arity}"},
      file: file,
      line: line
    )
  end
end
