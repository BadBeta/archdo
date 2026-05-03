defmodule Archdo.Rules.Module.CodeSlop do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.33"

  @impl true
  def description,
    do: "LLM-generated code slop — unnecessary verbosity, trivial wrappers, redundant patterns"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_slop(file, ast)
    end
  end

  defp find_slop(file, ast) do
    List.flatten([
      find_doc_on_private(file, ast),
      find_trivial_wrappers(file, ast),
      find_redundant_boolean(file, ast),
      find_empty_doc(file, ast),
      find_single_pipe(file, ast)
    ])
  end

  # --- @doc on private functions ---

  defp find_doc_on_private(file, ast) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        # @doc "..." followed by defp (in a block)
        {:__block__, _, items} = node, acc when is_list(items) ->
          new = scan_doc_before_defp(items, file)
          {node, new ++ acc}

        node, acc ->
          {node, acc}
      end)

    diagnostics
  end

  defp scan_doc_before_defp(items, file) do
    items
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [{:@, doc_meta, [{:doc, _, _}]}, {:defp, _, [{name, _, _} | _]}] ->
        [build_diagnostic(file, AST.line(doc_meta), :doc_on_private, %{function: name})]

      _ ->
        []
    end)
  end

  # --- Trivial delegation wrappers ---
  # defp foo(a, b), do: Module.foo(a, b) — same args, just forwarding

  defp find_trivial_wrappers(file, ast) do
    fns = AST.extract_functions(ast, :private)

    Enum.flat_map(fns, fn {name, arity, meta, args, body} ->
      case trivial_delegation?(name, arity, args, body) do
        {:yes, target} ->
          [
            build_diagnostic(file, AST.line(meta), :trivial_wrapper, %{
              function: "#{name}/#{arity}",
              target: target
            })
          ]

        :no ->
          []
      end
    end)
  end

  defp trivial_delegation?(name, arity, args, body) do
    # Body is a single remote call: Module.func(same_args)
    body
    |> unwrap_body()
    |> classify_wrapper(name, args, arity)
  end

  defp classify_wrapper(
         {{:., _, [{:__aliases__, _, mod_parts}, func_name]}, _, call_args},
         name,
         args,
         arity
       )
       when is_list(call_args) do
    matches? = length(call_args) == arity and args_match?(args, call_args)
    same_name? = func_name == name
    wrapper_verdict(matches? and same_name?, mod_parts, func_name)
  end

  defp classify_wrapper(_other, _name, _args, _arity), do: :no

  # §§ elixir-implementing: §2.1 — boolean → multi-clause head
  defp wrapper_verdict(false, _mod_parts, _func_name), do: :no

  defp wrapper_verdict(true, mod_parts, func_name) do
    target = Enum.map_join(mod_parts, ".", &Atom.to_string/1) <> ".#{func_name}"
    {:yes, target}
  end

  defp unwrap_body({:__block__, _, [single]}), do: single
  # Keyword-list body from literal_encoder: [{{:__block__, _, [:do]}, actual_body}]
  defp unwrap_body([{key, body}]) when is_tuple(key), do: unwrap_body(body)
  defp unwrap_body(body), do: body

  # Check if call args are the same variables as function params
  defp args_match?(params, call_args) when length(params) == length(call_args) do
    Enum.all?(Enum.zip(params, call_args), fn
      {{name, _, ctx1}, {name, _, ctx2}} when is_atom(ctx1) and is_atom(ctx2) -> true
      _ -> false
    end)
  end

  defp args_match?(_, _), do: false

  # --- Redundant == true / == false ---

  defp find_redundant_boolean(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        {:==, _, [_, true]} -> true
        {:==, _, [_, {:__block__, _, [true]}]} -> true
        {:==, _, [_, false]} -> true
        {:==, _, [_, {:__block__, _, [false]}]} -> true
        {:!=, _, [_, true]} -> true
        {:!=, _, [_, {:__block__, _, [true]}]} -> true
        {:!=, _, [_, false]} -> true
        {:!=, _, [_, {:__block__, _, [false]}]} -> true
        _ -> false
      end),
      fn {op, meta, [_expr, val]} ->
        bool_val = AST.unwrap_literal(val)

        build_diagnostic(file, AST.line(meta), :redundant_boolean, %{
          comparison: "#{op} #{bool_val}"
        })
      end
    )
  end

  # --- Empty @doc "" ---

  defp find_empty_doc(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        {:@, _, [{:doc, _, [""]}]} -> true
        {:@, _, [{:doc, _, [{:__block__, _, [""]}]}]} -> true
        {:@, _, [{:moduledoc, _, [""]}]} -> true
        {:@, _, [{:moduledoc, _, [{:__block__, _, [""]}]}]} -> true
        _ -> false
      end),
      fn {:@, meta, [{attr_name, _, _}]} ->
        build_diagnostic(file, AST.line(meta), :empty_doc, %{attribute: "@#{attr_name}"})
      end
    )
  end

  # --- Single pipe ---
  # x |> foo() — should be foo(x)
  # Multi-step pipelines nest as {:|>, _, [{:|>, _, [input, step1]}, step2]}.
  # Walk the AST collecting all pipe nodes, tracking which are inner (left child
  # of another pipe). Only flag pipes that are neither inner nor multi-step.

  defp find_single_pipe(file, ast) do
    {_, {all_pipes, inner_pipes}} =
      Macro.prewalk(ast, {[], MapSet.new()}, fn
        {:|>, meta, [left, _right]} = node, {pipes, inner} ->
          # This pipe's left child, if also a pipe, is an "inner" pipe
          inner =
            case left do
              {:|>, left_meta, _} -> MapSet.put(inner, AST.line(left_meta))
              _ -> inner
            end

          {node, {[{AST.line(meta), node} | pipes], inner}}

        node, acc ->
          {node, acc}
      end)

    for {line, {:|>, meta, [left, _]}} <- all_pipes,
        not MapSet.member?(inner_pipes, line),
        not match?({:|>, _, _}, left),
        do: build_diagnostic(file, AST.line(meta), :single_pipe, %{})
  end

  # --- Diagnostics ---

  defp build_diagnostic(file, line, :doc_on_private, %{function: name}) do
    Diagnostic.info("6.33",
      title: "Code slop: @doc on private function",
      message: "@doc before defp #{name} — private functions can't have external docs",
      why:
        "@doc annotations on private functions are ignored by ExDoc and indicate " <>
          "over-documentation. Use a code comment if the logic needs explanation.",
      alternatives: [
        Fix.new(
          summary: "Remove the @doc or change defp to def",
          detail: "If the function is truly public API, make it `def`. Otherwise remove `@doc`.",
          applies_when: "Always."
        )
      ],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :trivial_wrapper, %{function: func, target: target}) do
    Diagnostic.info("6.33",
      title: "Code slop: trivial delegation wrapper",
      message: "#{func} just delegates to #{target} with identical arguments",
      why:
        "A private function that simply forwards all arguments to another function " <>
          "with the same name adds an indirection layer with no value. Call the " <>
          "target directly, or use `defdelegate` if the wrapper is public.",
      alternatives: [
        Fix.new(
          summary: "Call #{target} directly at the call site",
          detail: "Remove the wrapper and call `#{target}(...)` where it's used.",
          applies_when: "The wrapper adds no logic, default args, or documentation."
        )
      ],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :redundant_boolean, %{comparison: comp}) do
    Diagnostic.info("6.33",
      title: "Code slop: redundant boolean comparison",
      message: "Explicit `#{comp}` — the expression is already a boolean",
      why:
        "Comparing a boolean to `true` or `false` is redundant. " <>
          "Use the value directly: `if active?` not `if active? == true`. " <>
          "In guards, use `when flag` not `when flag == true`.",
      alternatives: [
        Fix.new(
          summary: "Use the boolean value directly",
          detail: "`x == true` → `x`, `x == false` → `not x`, `x != true` → `not x`",
          applies_when: "The left side is known to return a boolean."
        )
      ],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :empty_doc, %{attribute: attr}) do
    Diagnostic.info("6.33",
      title: "Code slop: empty #{attr}",
      message: "#{attr} is an empty string — use `#{attr} false` to hide, or write actual docs",
      why:
        "An empty doc string is meaningless. Use `@doc false` to explicitly " <>
          "hide from documentation, or write a real description.",
      alternatives: [
        Fix.new(
          summary: "Use `#{attr} false` or write documentation",
          detail:
            "`#{attr} false` hides the item from ExDoc. An empty string just looks like a mistake.",
          applies_when: "Always."
        )
      ],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :single_pipe, _ctx) do
    Diagnostic.info("6.33",
      title: "Code slop: single-step pipeline",
      message: "Single `|>` pipe — use a direct function call instead",
      why:
        "Pipelines express multi-step data transformations. A single pipe " <>
          "`x |> foo()` is just a verbose way to write `foo(x)`. " <>
          "Reserve `|>` for 2+ transformations.",
      alternatives: [
        Fix.new(
          summary: "Call the function directly",
          detail: "`x |> Enum.map(&f/1)` → `Enum.map(x, &f/1)`",
          applies_when: "There is only one pipe operator in the expression."
        )
      ],
      file: file,
      line: line
    )
  end
end
