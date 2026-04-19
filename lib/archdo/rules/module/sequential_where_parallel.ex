defmodule Archdo.Rules.Module.SequentialWhereParallel do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.42"

  @impl true
  def description, do: "Sequential collection processing with I/O — candidate for parallelization"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_sequential_io(file, ast)
    end
  end

  # Known I/O modules — calls to these inside Enum.map suggest parallelization
  @io_modules ~w(
    Repo HTTPoison Finch Req Tesla Mint
    File System GenServer Agent
    Mailer Swoosh Bamboo
    ExAws Stripe
  )

  # Patterns that suggest I/O at the call level
  @io_function_patterns ~w(
    get get! post put patch delete
    insert insert! update update! all one
    fetch fetch! read read! write write!
    send deliver call cast
    request request!
  )a

  defp find_sequential_io(file, ast) do
    collection_io = find_collection_io(file, ast)
    sequential_independent = find_sequential_independent(file, ast)
    collection_io ++ sequential_independent
  end

  # --- Pattern 1: Enum.map/each/flat_map with I/O callback ---

  defp find_collection_io(file, ast) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        # Enum.map(collection, fn x -> ... end)
        {{:., _, [{:__aliases__, _, [:Enum]}, enum_fn]}, meta, [_collection, callback]} = node,
        acc
        when enum_fn in [:map, :each, :flat_map] ->
          case callback_has_io?(callback) do
            {true, io_target} ->
              {node, [build_collection_diagnostic(file, meta, enum_fn, io_target) | acc]}

            false ->
              {node, acc}
          end

        # Stream.map/each/flat_map — same pattern but with Stream
        {{:., _, [{:__aliases__, _, [:Stream]}, stream_fn]}, meta, [_collection, callback]} = node,
        acc
        when stream_fn in [:map, :each, :flat_map] ->
          case callback_has_io?(callback) do
            {true, io_target} ->
              {node, [build_collection_diagnostic(file, meta, :"Stream.#{stream_fn}", io_target) | acc]}

            false ->
              {node, acc}
          end

        # for comprehension with I/O in body
        {:for, meta, args} = node, acc when is_list(args) ->
          body = extract_for_body(args)

          case body_has_io?(body) do
            {true, io_target} ->
              {node, [build_for_diagnostic(file, meta, io_target) | acc]}

            false ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(diagnostics)
  end

  # --- Pattern 2: Sequential independent bindings ---

  defp find_sequential_independent(file, ast) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        # Look for function bodies with sequential independent bindings
        {def_type, meta, [{_name, _, _args}, [do: {:__block__, _, statements}]]} = node, acc
        when def_type in [:def, :defp] ->
          case find_independent_io_bindings(statements) do
            [] ->
              {node, acc}

            groups ->
              diags = Enum.map(groups, &build_sequential_diagnostic(file, meta, &1))
              {node, diags ++ acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(diagnostics)
  end

  # Check if an anonymous function callback contains I/O calls
  defp callback_has_io?({:fn, _, [{:->, _, [_args, body]}]}) do
    body_has_io?(body)
  end

  defp callback_has_io?({:fn, _, clauses}) when is_list(clauses) do
    Enum.find_value(clauses, false, fn
      {:->, _, [_args, body]} -> body_has_io?(body)
      _ -> false
    end)
  end

  # Function capture: &Module.func/arity
  defp callback_has_io?({:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, mod_parts}, func]}, _, _}, _arity]}]}) do
    mod_name = Enum.join(mod_parts, ".")

    case io_module?(mod_name) or io_function?(func) do
      true -> {true, "#{mod_name}.#{func}"}
      false -> false
    end
  end

  # Function capture: &func/arity (local)
  defp callback_has_io?({:&, _, [{:/, _, [{func, _, _}, _arity]}]}) when is_atom(func) do
    case io_function?(func) do
      true -> {true, "#{func}"}
      false -> false
    end
  end

  defp callback_has_io?(_), do: false

  defp body_has_io?(body) do
    {_, result} =
      Macro.prewalk(body, false, fn
        # Remote call: Module.function(args)
        {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, _args} = node, acc ->
          mod_name = Enum.join(mod_parts, ".")

          case io_module?(mod_name) or io_function?(func) do
            true -> {node, {true, "#{mod_name}.#{func}"}}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    result
  end

  defp extract_for_body(args) do
    case List.last(args) do
      [do: body] -> body
      _ -> nil
    end
  end

  # Find groups of sequential variable bindings that are independent I/O calls
  defp find_independent_io_bindings(statements) do
    # Extract bindings of the form: var = Module.func(args)
    bindings =
      statements
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:=, _, [{var_name, _, nil}, {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, args}]},
         idx}
        when is_atom(var_name) ->
          mod_name = Enum.join(mod_parts, ".")

          case io_module?(mod_name) or io_function?(func) do
            true ->
              arg_vars = extract_var_refs(args)
              [{var_name, idx, "#{mod_name}.#{func}", arg_vars}]

            false ->
              []
          end

        _ ->
          []
      end)

    # Find consecutive I/O bindings where later ones don't depend on earlier ones
    find_independent_groups(bindings, [])
  end

  defp find_independent_groups([], acc), do: Enum.reverse(acc)

  defp find_independent_groups([binding | rest], acc) do
    {group, remaining} = collect_independent(rest, [binding], MapSet.new([elem(binding, 0)]))

    case length(group) >= 2 do
      true -> find_independent_groups(remaining, [Enum.reverse(group) | acc])
      false -> find_independent_groups(rest, acc)
    end
  end

  defp collect_independent([], group, _defined), do: {group, []}

  defp collect_independent([{var, idx, call, deps} = binding | rest], group, defined) do
    # Check if this binding depends on any variable defined by the group
    depends_on_group = Enum.any?(deps, &MapSet.member?(defined, &1))

    # Check if it's consecutive (no gap)
    {_, prev_idx, _, _} = hd(group)

    case not depends_on_group and idx == prev_idx + 1 do
      true ->
        collect_independent(rest, [binding | group], MapSet.put(defined, var))

      false ->
        {group, [{var, idx, call, deps} | rest]}
    end
  end

  defp extract_var_refs(ast) do
    {_, vars} =
      Macro.prewalk(ast, [], fn
        {name, _, nil} = node, acc when is_atom(name) ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  defp io_module?(mod_name) do
    Enum.any?(@io_modules, fn io_mod ->
      mod_name == io_mod or String.ends_with?(mod_name, ".#{io_mod}")
    end)
  end

  defp io_function?(func), do: func in @io_function_patterns

  # --- Diagnostics ---

  defp build_collection_diagnostic(file, meta, enum_fn, io_target) do
    line = AST.line(meta)

    Diagnostic.info("5.42",
      title: "Sequential I/O in collection processing",
      message:
        "#{enum_fn} calls #{io_target} sequentially — " <>
          "consider Task.async_stream for parallel execution",
      why:
        "This #{enum_fn} call processes each element sequentially, but each iteration " <>
          "calls #{io_target} which involves I/O (network, database, or filesystem). " <>
          "Since iterations are independent, they can run in parallel with " <>
          "Task.async_stream/3, which uses a pool of async tasks with backpressure. " <>
          "For N items with T seconds of I/O each: sequential = N*T, parallel ≈ T.",
      alternatives: [
        Fix.new(
          summary: "Replace with Task.async_stream",
          detail:
            "collection\n" <>
              "|> Task.async_stream(&process/1, max_concurrency: 10, ordered: true)\n" <>
              "|> Enum.map(fn {:ok, result} -> result end)\n\n" <>
              "Set max_concurrency to limit parallel work. Use ordered: false " <>
              "if result order doesn't matter (slightly faster).",
          applies_when: "Each iteration is independent and involves I/O."
        ),
        Fix.new(
          summary: "Use Flow for large datasets",
          detail:
            "For very large collections (1000+ items), Flow provides partition-based " <>
              "parallelism: Flow.from_enumerable(items) |> Flow.map(&process/1)",
          applies_when: "The collection is large and processing is CPU-bound."
        ),
        Fix.new(
          summary: "Keep sequential if ordering or rate limiting matters",
          detail:
            "Sequential processing is correct when: iterations must happen in order, " <>
              "the external service has rate limits, or error handling requires " <>
              "stopping on first failure.",
          applies_when: "Order, rate limits, or fail-fast behavior is required."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.42"],
      context: %{
        pattern: to_string(enum_fn),
        io_target: io_target
      },
      file: file,
      line: line
    )
  end

  defp build_for_diagnostic(file, meta, io_target) do
    line = AST.line(meta)

    Diagnostic.info("5.42",
      title: "Sequential I/O in for comprehension",
      message:
        "for comprehension calls #{io_target} sequentially — " <>
          "consider Task.async_stream for parallel execution",
      why:
        "This for comprehension processes elements sequentially with I/O in the body. " <>
          "If iterations are independent, replacing with Task.async_stream " <>
          "can significantly reduce wall-clock time.",
      alternatives: [
        Fix.new(
          summary: "Replace with Task.async_stream",
          detail: "Extract the for body into a function and use Task.async_stream.",
          applies_when: "Each iteration is independent and involves I/O."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.42"],
      context: %{pattern: "for", io_target: io_target},
      file: file,
      line: line
    )
  end

  defp build_sequential_diagnostic(file, meta, group) do
    line = AST.line(meta)

    calls =
      group
      |> Enum.map(fn {var, _idx, call, _deps} -> "#{var} = #{call}(...)" end)
      |> Enum.join(", ")

    count = length(group)

    Diagnostic.info("5.42",
      title: "Sequential independent I/O calls",
      message:
        "#{count} independent I/O calls in sequence: #{calls} — " <>
          "consider parallel execution with Task.async",
      why:
        "These #{count} bindings each perform independent I/O and don't depend on " <>
          "each other's results. Running them in parallel with Task.async/Task.await " <>
          "would reduce the total wait time from the sum of all calls to approximately " <>
          "the slowest single call.",
      alternatives: [
        Fix.new(
          summary: "Use Task.async for parallel independent calls",
          detail:
            "task1 = Task.async(fn -> first_call() end)\n" <>
              "task2 = Task.async(fn -> second_call() end)\n" <>
              "result1 = Task.await(task1)\n" <>
              "result2 = Task.await(task2)",
          applies_when: "The calls are truly independent."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.42"],
      context: %{pattern: "sequential_bindings", call_count: count, calls: calls},
      file: file,
      line: line
    )
  end
end
