defmodule Archdo.Rules.Composition.PipelineSideEffectTerminator do
  @moduledoc false
  @behaviour Archdo.Rule

  # 10.4. A function that performs a known side effect (Logger,
  # telemetry, Phoenix.PubSub, Repo writes, IO writes, File writes)
  # but returns a value that is neither the first parameter's type
  # nor `{:ok, T}` over it. The caller cannot pipe the result onward
  # because the input was consumed without being passed through.
  # Recoverable by returning the input value (or `{:ok, input}`).

  alias Archdo.{AST, Diagnostic, Fix}

  # Side-effect call catalog. Two forms:
  #   - `{module_parts, :any}` — every call to the module is a side
  #     effect (Logger.info / Logger.warning / Logger.error / etc.)
  #   - `{module_parts, [fun, ...]}` — only specific functions count.
  #     This is what distinguishes Repo writes from Repo reads:
  #     `Repo.insert/update/delete` ARE side effects (the input is
  #     persisted and the wrapping function commonly drops it);
  #     `Repo.get/get_by/all/one/exists?` are reads — the first arg
  #     is criteria, not the pipeline subject, so a query returning
  #     a different shape is NOT a "lost subject" anti-pattern.
  @side_effect_calls [
    {[:Logger], :any},
    {[:Phoenix, :PubSub],
     [
       :broadcast,
       :broadcast!,
       :broadcast_from,
       :broadcast_from!,
       :local_broadcast,
       :local_broadcast_from
     ]},
    {[:Repo],
     [
       :insert,
       :insert!,
       :insert_all,
       :insert_or_update,
       :insert_or_update!,
       :update,
       :update!,
       :update_all,
       :delete,
       :delete!,
       :delete_all
     ]},
    {[:Ecto, :Repo],
     [
       :insert,
       :insert!,
       :insert_all,
       :insert_or_update,
       :insert_or_update!,
       :update,
       :update!,
       :update_all,
       :delete,
       :delete!,
       :delete_all
     ]},
    {[:IO], [:puts, :write, :binwrite, :inspect_no_op]},
    {[:File],
     [
       :write,
       :write!,
       :touch,
       :touch!,
       :mkdir,
       :mkdir!,
       :mkdir_p,
       :mkdir_p!,
       :rm,
       :rm!,
       :rmdir,
       :rmdir!,
       :cp,
       :cp!,
       :cp_r,
       :cp_r!,
       :rename,
       :chmod,
       :chmod!,
       :chown,
       :chown!
     ]}
  ]

  # Erlang-style atom-prefix calls. `:telemetry.execute` is the
  # observability call worth tracking; `:logger` is the OTP logger.
  @side_effect_atom_calls [
    {:telemetry, [:execute, :span]},
    {:logger, :any}
  ]

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
      contains_ok_tuple?(return_type) or
      union_contains?(return_type, first_arg_key)
  end

  # Any `{:ok, _}` in the return shape — including unions like
  # `{:ok, U} | {:error, _}` — counts as compose-able. The function
  # returns a wrapped value the caller can chain via `with`, even if
  # U is not the first-arg type (constructor pattern: first arg is
  # context, return is the new entity).
  #
  # Production parser (`literal_encoder`) wraps every 2-tuple with
  # atom keys in `{:__block__, _, [tuple]}`; the unwrap clause
  # handles both that form and the plain quoted form used in tests.
  defp contains_ok_tuple?({:__block__, _, [inner]}), do: contains_ok_tuple?(inner)

  # 2-tuple `{:ok, T}` — bare and literal-encoded forms.
  defp contains_ok_tuple?({{:__block__, _, [:ok]}, _}), do: true
  defp contains_ok_tuple?({:ok, _}), do: true

  # 3+ tuple with :ok head — `{:ok, A, B, ...}`. AST shape is
  # `{:{}, _, [:ok | _]}` either with the head wrapped or bare.
  defp contains_ok_tuple?({:{}, _, [{:__block__, _, [:ok]} | _]}), do: true
  defp contains_ok_tuple?({:{}, _, [:ok | _]}), do: true

  defp contains_ok_tuple?({:|, _, [left, right]}),
    do: contains_ok_tuple?(left) or contains_ok_tuple?(right)

  defp contains_ok_tuple?(_), do: false

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

  defp side_effect_call?({{:., _, [{:__aliases__, _, parts}, fun]}, _, _})
       when is_atom(fun) do
    Enum.any?(@side_effect_calls, fn
      {^parts, :any} -> true
      {^parts, funs} when is_list(funs) -> fun in funs
      _ -> false
    end)
  end

  defp side_effect_call?({{:., _, [mod, fun]}, _, _})
       when is_atom(mod) and is_atom(fun) do
    Enum.any?(@side_effect_atom_calls, fn
      {^mod, :any} -> true
      {^mod, funs} when is_list(funs) -> fun in funs
      _ -> false
    end)
  end

  defp side_effect_call?(_), do: false

  defp build_diagnostic(file, name, arity, meta) do
    Diagnostic.info("10.4",
      title: "Side-effect function does not pass input through",
      message:
        "#{name}/#{arity} performs a side effect (Logger / telemetry / PubSub / Repo write / IO write / File write) " <>
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
