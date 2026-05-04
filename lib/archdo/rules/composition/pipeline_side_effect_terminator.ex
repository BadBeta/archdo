defmodule Archdo.Rules.Composition.PipelineSideEffectTerminator do
  @moduledoc false
  @behaviour Archdo.Rule

  # 10.4. A function that performs a known side effect (Logger,
  # telemetry, PubSub, Repo write, IO) but returns a value that is
  # neither the first parameter's type nor `{:ok, T}` over it. The
  # caller cannot pipe the result onward because the input was
  # consumed without being passed through. Recoverable by returning
  # the input value (or `{:ok, input}`) after the effect.

  alias Archdo.{AST, Diagnostic, Fix}

  @side_effect_modules [
    [:Logger],
    [:Phoenix, :PubSub],
    [:Repo],
    [:Ecto, :Repo],
    [:File],
    [:IO]
  ]

  # Erlang-style atom-prefix calls (`:telemetry.*`, `:logger.*`).
  @side_effect_atom_modules [:telemetry, :logger, :file, :gen_tcp, :gen_udp]

  @impl true
  def id, do: "10.4"

  @impl true
  def description,
    do: "Side-effecting function does not pass its input through to the output (terminates pipelines)"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_terminators(file, ast)
    end
  end

  defp find_terminators(file, ast) do
    spec_signatures = collect_spec_signatures(ast)
    publics_by_key = ast |> AST.extract_functions(:public) |> Map.new(&function_key/1)

    Enum.flat_map(spec_signatures, fn {name, arity, arg_types, return_type, meta} ->
      with true <- Map.has_key?(publics_by_key, {name, arity}),
           true <- arity >= 1,
           {:ok, first_arg_type} <- first_concrete_arg_type(arg_types),
           false <- return_compatible?(return_type, first_arg_type),
           {_args, body} <- Map.fetch!(publics_by_key, {name, arity}),
           true <- has_side_effect_call?(body) do
        [build_diagnostic(file, name, arity, meta)]
      else
        _ -> []
      end
    end)
  end

  defp function_key({name, arity, _meta, args, body}), do: {{name, arity}, {args, body}}

  defp collect_spec_signatures(ast) do
    {_, list} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:spec, meta, [{:"::", _, [{name, _, args}, return]}]}]} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, [{name, length(args), args, return, meta} | acc]}

        node, acc ->
          {node, acc}
      end)

    list
  end

  # any() / term() / no concrete shape → nothing to match against, skip.
  defp first_concrete_arg_type([first | _]) do
    case concrete_type?(first) do
      true -> {:ok, type_key(first)}
      false -> :no_concrete_type
    end
  end

  defp first_concrete_arg_type(_), do: :no_args

  defp concrete_type?({:any, _, _}), do: false
  defp concrete_type?({:term, _, _}), do: false
  defp concrete_type?(_), do: true

  defp return_compatible?(return_type, first_arg_key) do
    type_key(return_type) == first_arg_key or
      ok_tuple_of?(return_type, first_arg_key) or
      union_contains?(return_type, first_arg_key)
  end

  # `{:ok, T}` and `{:ok, T} | {:error, _}` patterns.
  defp ok_tuple_of?({{:__block__, _, [:ok]}, t}, target_key), do: type_key(t) == target_key
  defp ok_tuple_of?({:ok, t}, target_key), do: type_key(t) == target_key
  defp ok_tuple_of?(_, _), do: false

  # Walk a pipe-shaped union (`a | b | c` → `{:|, _, [a, {:|, _, [b, c]}]}`).
  defp union_contains?({:|, _, [left, right]}, target_key) do
    return_compatible?(left, target_key) or return_compatible?(right, target_key)
  end

  defp union_contains?(_, _), do: false

  defp type_key(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
  end

  defp has_side_effect_call?(body) do
    body
    |> AST.do_body()
    |> walk_for_side_effect()
  end

  defp walk_for_side_effect(nil), do: false

  defp walk_for_side_effect(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        node, true ->
          {node, true}

        node, false ->
          {node, side_effect_call?(node)}
      end)

    found?
  end

  defp side_effect_call?({{:., _, [{:__aliases__, _, parts}, _fun]}, _, _}) do
    parts in @side_effect_modules
  end

  defp side_effect_call?({{:., _, [mod, _fun]}, _, _}) when is_atom(mod) do
    mod in @side_effect_atom_modules
  end

  defp side_effect_call?(_), do: false

  defp build_diagnostic(file, name, arity, meta) do
    Diagnostic.info("10.4",
      title: "Side-effect function does not pass input through",
      message:
        "#{name}/#{arity} performs a side effect (Logger / telemetry / PubSub / Repo / IO) " <>
          "but returns a value that drops the input — the function terminates any pipeline " <>
          "that flows through it",
      why:
        "Pipelines compose by feeding one function's output into the next function's first " <>
          "argument. When a function takes T, performs an observability effect, and returns " <>
          "`:ok` / `nil` / an unrelated atom, the caller must split the pipeline (assign a " <>
          "name, call the function for its effect, then continue with the original value). " <>
          "Returning T (or `{:ok, T}`) keeps the chain intact and makes the function " <>
          "composable.",
      alternatives: [
        Fix.new(
          summary: "Return the input after the side effect",
          detail:
            "Replace the trailing `:ok` / `nil` with the function's first parameter. The " <>
              "side effect still happens; the return value now allows downstream chaining.",
          applies_when: "The side effect is observability, not a domain-meaningful result."
        ),
        Fix.new(
          summary: "Wrap the input in `{:ok, _}` if errors are possible",
          detail:
            "If the side effect can fail and the function should signal failure, return " <>
              "`{:ok, input}` on success and `{:error, reason}` on failure. The shape composes " <>
              "via `with` chains.",
          applies_when: "Failure is a real possibility worth reporting."
        )
      ],
      references: [],
      context: %{function: "#{name}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
