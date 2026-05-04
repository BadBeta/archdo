defmodule Archdo.Rules.Composition.PipelineShapeMismatch do
  @moduledoc false
  @behaviour Archdo.Rule

  # 10.5. Cross-module pipeline mismatch: a producer function `g/n`
  # whose `@spec` return is a tuple of types `{T1, T2, ..., Tk}` and a
  # consumer function `f/k` whose `@spec` input types are the same
  # multiset of types, but in a different order. The pipeline
  # `g(...) |> elem-by-elem |> f(...)` is impossible without manual
  # re-shuffling — the call has to be written `f(elem(g(), 1), elem(g(), 0))`
  # or via destructuring. Resolution (reorder producer vs consumer) is
  # the developer's call; this rule only flags the structural mismatch.

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "10.5"

  @impl true
  def description,
    do: "Producer's tuple output is a permutation of a consumer's input order (no pipeline possible)"

  @doc """
  Project-level analysis. Walks every file's specs, indexes producer
  return-tuple shapes and consumer input-tuple shapes, and reports
  every (producer, consumer) pair whose types are the same multiset
  but in different order.
  """
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, _opts \\ []) do
    production = Enum.reject(file_asts, fn {file, _} -> AST.test_file?(file) end)

    {producers, consumers} = collect_signatures(production)

    for producer <- producers,
        consumer <- consumers,
        not same_function?(producer, consumer),
        types_permute?(producer, consumer) do
      build_diagnostic(producer, consumer)
    end
  end

  defp collect_signatures(file_asts) do
    Enum.reduce(file_asts, {[], []}, fn {file, ast}, {prods, cons} ->
      module = AST.extract_module_name(ast)
      specs = collect_spec_signatures(ast)
      {add_producers(specs, file, module, prods), add_consumers(specs, file, module, cons)}
    end)
  end

  defp add_producers(specs, file, module, acc) do
    Enum.reduce(specs, acc, fn {name, arity, _args, return, meta}, list ->
      case tuple_elements(return) do
        nil ->
          list

        elements ->
          [%{file: file, module: module, name: name, arity: arity, types: elements, meta: meta} | list]
      end
    end)
  end

  defp add_consumers(specs, file, module, acc) do
    Enum.reduce(specs, acc, fn {name, arity, args, _return, meta}, list ->
      case arity do
        a when a >= 2 ->
          [%{file: file, module: module, name: name, arity: arity, types: args, meta: meta} | list]

        _ ->
          list
      end
    end)
  end

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

  defp tuple_elements({:{}, _, elements}) when is_list(elements) and length(elements) >= 2,
    do: elements

  defp tuple_elements({a, b}), do: [a, b]
  defp tuple_elements(_), do: nil

  defp same_function?(producer, consumer) do
    producer.module == consumer.module and
      producer.name == consumer.name and
      producer.arity == consumer.arity
  end

  defp types_permute?(producer, consumer) do
    producer_keys = Enum.map(producer.types, &type_key/1)
    consumer_keys = Enum.map(consumer.types, &type_key/1)

    length(producer_keys) == length(consumer_keys) and
      producer_keys != consumer_keys and
      Enum.sort(producer_keys) == Enum.sort(consumer_keys)
  end

  defp type_key(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
  end

  defp build_diagnostic(producer, consumer) do
    Diagnostic.info("10.5",
      title: "Pipeline shape mismatch between producer and consumer",
      message:
        "#{short(producer)} returns a tuple of types that #{short(consumer)} accepts, " <>
          "but in a different order — the pipeline cannot be expressed without re-shuffling",
      why:
        "Pipelines compose by feeding one function's output into the next function's first " <>
          "argument. When a producer returns `{T1, T2}` and a consumer takes `(T2, T1)` the " <>
          "type sets match but the order does not, so the pipeline `producer() |> consumer()` " <>
          "won't typecheck. Either the producer or the consumer should be reordered. The " <>
          "right fix depends on which has fewer callers and which one is downstream.",
      alternatives: [
        Fix.new(
          summary: "Reorder #{short(producer)} to match #{short(consumer)}",
          detail:
            "Change the producer's return tuple order so the pipeline composes. Use this when " <>
              "the producer has fewer or no other callers.",
          applies_when: "The producer's return order is incidental, not part of its contract."
        ),
        Fix.new(
          summary: "Reorder #{short(consumer)} to match #{short(producer)}",
          detail:
            "Change the consumer's parameter order so the pipeline composes. Use this when " <>
              "the consumer has fewer callers and the producer's order is the established one.",
          applies_when: "The consumer is the newer function or has fewer call sites."
        )
      ],
      references: [],
      context: %{
        producer: short(producer),
        consumer: short(consumer)
      },
      file: producer.file,
      line: AST.line(producer.meta)
    )
  end

  defp short(%{module: module, name: name, arity: arity}),
    do: "#{module}.#{name}/#{arity}"
end
