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
  def description, do: "Detect code duplication — Type-2 clones (structurally identical functions)"

  @impl true
  def analyze(_file, _ast, _opts), do: []

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
    duplicates
    |> Enum.flat_map(fn {_hash, infos} ->
      [first | rest] = Enum.sort_by(infos, & &1.file)
      build_diagnostics(first, rest)
    end)
  end

  defp build_diagnostics(first, rest) do
    other_locations =
      rest
      |> Enum.map(fn info -> "#{Path.basename(info.file)}:#{info.line}" end)
      |> Enum.join(", ")

    count = length(rest) + 1

    [
      Diagnostic.warning("3.1",
        title: "Structurally identical function clone",
        message:
          "#{first.name}/#{first.arity} (#{first.size} AST nodes) is structurally identical to #{count - 1} other function(s): #{other_locations}",
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
            applies_when: "The clones evolve independently and unifying them would create false coupling."
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
    files = Enum.map(infos, & &1.file) |> Enum.uniq()
    length(files) == 1
  end

  defp extract_functions_with_hashes(file, ast) do
    fns = AST.extract_functions(ast, :all)

    fns
    |> Enum.reject(fn {name, _arity, _meta, _args, _body} -> name in @ignored_callbacks end)
    |> Enum.map(fn {name, arity, meta, _args, body} ->
      normalized = normalize(body)
      size = ast_size(normalized)
      hash = :erlang.phash2(normalized)

      {hash,
       %{
         file: file,
         name: name,
         arity: arity,
         line: AST.line(meta),
         size: size
       }}
    end)
    |> Enum.filter(fn {_hash, info} -> info.size >= @min_node_count end)
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

  # Variable reference: {name, meta, context} where name and context are atoms
  defp normalize_node({name, _meta, context}, state)
       when is_atom(name) and is_atom(context) do
    case Map.get(state.mapping, name) do
      nil ->
        new_id = state.counter
        new_state = %{state | counter: state.counter + 1, mapping: Map.put(state.mapping, name, new_id)}
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

  # Count AST nodes for size threshold — manual recursion since Macro.prewalk
  # rejects our custom normalized form (integer in 3rd position).
  defp ast_size(nil), do: 0

  defp ast_size({a, b, c}), do: 1 + ast_size(a) + ast_size(b) + ast_size(c)
  defp ast_size({a, b}), do: 1 + ast_size(a) + ast_size(b)
  defp ast_size(list) when is_list(list), do: Enum.sum(Enum.map(list, &ast_size/1))
  defp ast_size(_), do: 1

end
