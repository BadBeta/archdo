defmodule Archdo.Rules.Module.DuplicatedCode do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # Minimum AST node count to consider — below this is boilerplate
  @min_node_count 15
  # Standard callbacks that are expected to look identical across modules
  @ignored_callbacks ~w(
    init child_spec start_link handle_call handle_cast handle_info handle_continue
    terminate code_change format_status
    mount render handle_event handle_params handle_async update
    new changeset
  )a

  @impl true
  def id, do: "3.1"

  @impl true
  def description,
    do: "Detect code duplication — Type-2 clones (structurally identical functions)"

  @doc """
  Project-level: walk all functions in all files, normalize, hash, group by hash.
  Functions sharing a hash are structural duplicates.
  """
  def analyze_project(file_asts) do
    # Build {hash, [{file, function_name, arity, line, size}]}
    by_hash =
      file_asts
      |> Enum.flat_map(fn {file, ast} ->
        if AST.test_file?(file) do
          []
        else
          extract_functions_with_hashes(file, ast)
        end
      end)
      |> Enum.group_by(fn {hash, _info} -> hash end, fn {_hash, info} -> info end)

    # Find buckets with >1 entries
    duplicates =
      by_hash
      |> Enum.filter(fn {_hash, infos} -> length(infos) > 1 end)
      |> Enum.reject(fn {_hash, infos} -> only_in_same_file?(infos) end)

    # Build diagnostics
    Enum.flat_map(duplicates, fn {_hash, infos} ->
      [first | rest] = Enum.sort_by(infos, & &1.file)
      build_diagnostics(first, rest, infos)
    end)
  end

  # §§ elixir-implementing: §2.1 — multi-clause dispatch on the
  # umbrella-shape predicate. Cross-app clones in an umbrella are
  # often deliberate (parallel implementations across deployables);
  # downgrade to :info. Same-app clones stay :warning.
  defp build_diagnostics(first, rest, all_infos) do
    other_locations =
      Enum.map_join(rest, ", ", fn info -> "#{AST.relative_path(info.file)}:#{info.line}" end)

    count = length(rest) + 1
    builder = severity_builder_for(all_infos)
    cohort_layer = cohort_layer_for(all_infos)

    title =
      case cohort_layer do
        nil -> "Structurally identical function clone"
        layer -> "Cohort clone: #{count} modules under #{layer}/ share the same shape"
      end

    message =
      case cohort_layer do
        nil ->
          "#{first.name}/#{first.arity} (#{first.size} AST nodes) is structurally identical to #{count - 1} other function(s): #{other_locations}"

        layer ->
          "#{first.name}/#{first.arity} (#{first.size} AST nodes) — #{count} modules under #{layer}/ share this shape: #{other_locations}. " <>
            "Confirm intentional enumeration (typical for code generators, protocol implementations, behaviour adapters) — if not, consider parameterizing."
      end

    [
      builder.("3.1",
        title: title,
        message: message,
        why:
          "Type-2 clones — functions with the same structure but possibly renamed variables — start as a " <>
            "convenient copy-paste and end as the most painful kind of duplication. Bug fixes and behaviour " <>
            "changes have to be applied in N places, and the copies inevitably drift apart, so the same logic " <>
            "produces subtly different results in different parts of the system.",
        alternatives: [
          Fix.new(
            summary: "Extract the shared logic into one function and call it from each site",
            detail:
              "Find the common shape, parameterize the parts that differ between copies, and replace each " <>
                "duplicate with a call. The shared function is now the single source of truth and bug fixes " <>
                "land in one place.",
            applies_when: "The functions really are doing the same thing."
          ),
          Fix.new(
            summary: "Extract a shared behaviour and parameterize via callbacks",
            detail:
              "If the functions differ in one or two specific steps but share a skeleton, define a behaviour " <>
                "with the variant steps as callbacks. Each duplicate becomes a thin behaviour implementation.",
            applies_when: "The duplicates differ in well-defined hot spots."
          ),
          Fix.new(
            summary: "Accept the duplication if it's coincidental",
            detail:
              "Sometimes structurally identical functions are not conceptually the same — a CRUD module and " <>
                "an event handler might both pattern-match a struct and update a field, but they will evolve " <>
                "independently. If extracting would couple unrelated concepts, leave them and add the freeze baseline.",
            applies_when:
              "The clones evolve independently and unifying them would create false coupling."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#3.1"],
        context: %{
          function: "#{first.name}/#{first.arity}",
          size: first.size,
          duplicate_count: count - 1,
          duplicates: other_locations
        },
        file: first.file,
        line: first.line
      )
    ]
  end

  defp only_in_same_file?(infos) do
    files = Enum.uniq(Enum.map(infos, & &1.file))
    length(files) == 1
  end

  # §§ M-fb-F6 — when 3+ clones share the same parent directory (one
  # layer below `lib/<app>/`), they're almost certainly an intentional
  # enumeration — generators, protocol impls, behaviour adapters,
  # CRUD controllers in a Phoenix layer. The clones are still real, but
  # the diagnosis shifts: "confirm intentional" instead of "consolidate."
  # Returns the layer name (last segment of the parent dir) or nil.
  # §§ elixir-implementing: §2.3 — head-pattern check for "≥ 3 elements"
  # is O(1); `length(infos) >= 3` would be O(n).
  defp cohort_layer_for([_, _, _ | _] = infos) do
    parents = infos |> Enum.map(&parent_dir/1) |> Enum.uniq()

    case parents do
      [single] when is_binary(single) -> Path.basename(single)
      _ -> nil
    end
  end

  defp cohort_layer_for(_), do: nil

  defp parent_dir(%{file: file}) do
    file
    |> AST.relative_path()
    |> Path.dirname()
  end

  # When all clones share the same umbrella app prefix → :warning
  # (within-app duplication is real architectural debt).
  # When they span different sibling apps → :info (often deliberate).
  defp severity_builder_for(infos) do
    apps = infos |> Enum.map(&umbrella_app/1) |> Enum.uniq()

    case apps do
      [nil] -> &Diagnostic.warning/2
      [_single_app] -> &Diagnostic.warning/2
      _ -> &Diagnostic.info/2
    end
  end

  # Returns the umbrella sibling app name (e.g. "api" for
  # `apps/api/lib/api/foo.ex`) or nil for non-umbrella paths.
  defp umbrella_app(%{file: file}) do
    case String.split(file, "/") do
      ["apps", app | _] -> app
      [_ | _] = parts -> apps_segment_after(Enum.find_index(parts, &(&1 == "apps")), parts)
      _ -> nil
    end
  end

  defp apps_segment_after(nil, _parts), do: nil
  defp apps_segment_after(idx, parts), do: Enum.at(parts, idx + 1)

  # Multi-clause heads of the same {name, arity} aggregate to ONE entry per
  # file. Without aggregation, each clause hashes individually and clauses
  # of the same function flag each other as self-clones (false positive on
  # any function whose clauses share body shape — e.g. recursive AST
  # walkers with their no-op fallback clauses).
  #
  # The hash is `{arity, [normalized_body, ...]}` — different arities never
  # collide even when bodies coincide (false positive on `f/2 ↔ g/3` where
  # the body literal happens to match).
  defp extract_functions_with_hashes(file, ast) do
    extract_with_guards(ast)
    |> Enum.reject(fn {name, _, _, _, _, _} -> name in @ignored_callbacks end)
    |> Enum.group_by(
      fn {name, arity, _, _, _, _} -> {name, arity} end,
      fn {_, _, meta, args, guards, body} -> {meta, args, guards, body} end
    )
    |> Enum.map(&hash_function_group(&1, file))
    |> Enum.filter(fn {_hash, info} -> info.size >= @min_node_count end)
  end

  # Walks `ast` and returns one tuple per `def`/`defp` clause as
  # `{name, arity, meta, args, guards, body}`. Differs from
  # `AST.extract_functions/2` only in that GUARDS are returned alongside
  # args — clone detection treats `f(x) when is_atom(x)` and
  # `f(x) when is_binary(x)` as distinct even if their bodies coincide.
  defp extract_with_guards(ast) do
    {_, fns} = Macro.prewalk(ast, [], &collect_def_with_guards/2)
    Enum.reverse(fns)
  end

  defp collect_def_with_guards(
         {kind, meta, [{:when, _, [{name, _, args} | guards]}, body]} = node,
         acc
       )
       when kind in [:def, :defp] and is_atom(name) and is_list(args) do
    {node, [{name, length(args), meta, args, guards, body} | acc]}
  end

  defp collect_def_with_guards({kind, meta, [{name, _, args}, body]} = node, acc)
       when kind in [:def, :defp] and is_atom(name) and is_list(args) do
    {node, [{name, length(args), meta, args, [], body} | acc]}
  end

  defp collect_def_with_guards({kind, meta, [{name, _, nil}, body]} = node, acc)
       when kind in [:def, :defp] and is_atom(name) do
    {node, [{name, 0, meta, [], [], body} | acc]}
  end

  defp collect_def_with_guards(node, acc), do: {node, acc}

  # The hash includes both ARG PATTERNS and BODIES of every clause. Two
  # functions whose bodies are identical (e.g. `do: true` / `do: false`)
  # but whose head patterns differ (`f({:_, _, _})` vs `f({:def, _, _})`)
  # are NOT duplicates — they're discriminating different shapes. Hashing
  # `{arity, [{normalized_args, normalized_body}, ...]}` distinguishes
  # them, while still grouping multi-clause heads of the same function.
  defp hash_function_group({{name, arity}, clauses}, file) do
    clauses_sorted = Enum.sort_by(clauses, fn {meta, _, _, _} -> AST.line(meta) end)

    clause_shapes =
      Enum.map(clauses_sorted, fn {_meta, args, guards, body} ->
        {normalize(args), normalize(guards), normalize(body)}
      end)

    size =
      Enum.sum(
        Enum.map(clause_shapes, fn {args_n, guards_n, body_n} ->
          AST.ast_size(args_n) + AST.ast_size(guards_n) + AST.ast_size(body_n)
        end)
      )

    hash = :erlang.phash2({arity, clause_shapes})
    {first_meta, _, _, _} = hd(clauses_sorted)

    {hash,
     %{
       file: file,
       name: name,
       arity: arity,
       line: AST.line(first_meta),
       size: size
     }}
  end

  @doc """
  Normalize an AST for structural comparison:
  - Strip all metadata (line numbers, columns)
  - Replace variable references with positional placeholders
  - Keep function calls, literals, control flow structure
  """
  def normalize(nil), do: nil

  def normalize(ast) do
    {normalized, _vars} = normalize_node(ast, %{counter: 0, mapping: %{}})
    normalized
  end

  # Module attribute READ: {:@, meta, [{attr_name, _, ctx}]} where ctx is
  # nil or an atom (context). Preserve `attr_name` as a literal — different
  # `@foo` and `@bar` references are distinct semantic identities, not
  # interchangeable variable bindings. (Two functions referencing the SAME
  # `@foo` still hash equal — that's a real cross-module clone.)
  defp normalize_node({:@, _meta, [{attr_name, _, ctx}]}, state)
       when is_atom(attr_name) and (is_nil(ctx) or is_atom(ctx)) do
    {{:@, [], [{attr_name, [], nil}]}, state}
  end

  # Variable reference: {name, meta, context} where name and context are atoms
  defp normalize_node({name, _meta, context}, state)
       when is_atom(name) and is_atom(context) do
    case Map.get(state.mapping, name) do
      nil ->
        new_id = state.counter

        new_state = %{
          state
          | counter: state.counter + 1,
            mapping: Map.put(state.mapping, name, new_id)
        }

        {{:_VAR, [], new_id}, new_state}

      id ->
        {{:_VAR, [], id}, state}
    end
  end

  # Generic AST 3-tuple: {form, meta, args} — strip meta, recurse into form and args
  defp normalize_node({form, meta, args}, state) when is_list(meta) do
    {form_n, s1} = normalize_node(form, state)
    {args_n, s2} = normalize_node(args, s1)
    {{form_n, [], args_n}, s2}
  end

  # 3-tuples that aren't AST nodes (rare — meta is not a list)
  defp normalize_node({a, b, c}, state) do
    {a_n, s1} = normalize_node(a, state)
    {b_n, s2} = normalize_node(b, s1)
    {c_n, s3} = normalize_node(c, s2)
    {{a_n, b_n, c_n}, s3}
  end

  # Lists: walk each element
  defp normalize_node(list, state) when is_list(list) do
    normalize_list(list, state)
  end

  # 2-tuples (keyword pairs)
  defp normalize_node({a, b}, state) do
    {a_n, s1} = normalize_node(a, state)
    {b_n, s2} = normalize_node(b, s1)
    {{a_n, b_n}, s2}
  end

  # Maps
  defp normalize_node(%{} = map, state) when not is_struct(map) do
    {pairs, new_state} =
      Enum.reduce(Map.to_list(map), {[], state}, fn {k, v}, {acc, s} ->
        {k_n, s1} = normalize_node(k, s)
        {v_n, s2} = normalize_node(v, s1)
        {[{k_n, v_n} | acc], s2}
      end)

    {Map.new(Enum.reverse(pairs)), new_state}
  end

  # Atoms, numbers, strings, binaries — kept as-is
  defp normalize_node(literal, state), do: {literal, state}

  defp normalize_list(list, state) do
    {acc, new_state} =
      Enum.reduce(list, {[], state}, fn item, {items, s} ->
        {n, s2} = normalize_node(item, s)
        {[n | items], s2}
      end)

    {Enum.reverse(acc), new_state}
  end
end
