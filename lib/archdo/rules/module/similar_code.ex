defmodule Archdo.Rules.Module.SimilarCode do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Rules.Module.DuplicatedCode

  # Configuration
  @shingle_size 5
  @similarity_threshold 0.75
  @min_node_count 25
  @max_pairs_to_report 50

  @ignored_callbacks ~w(
    init child_spec start_link handle_call handle_cast handle_info handle_continue
    terminate code_change format_status
    mount render handle_event handle_params handle_async update
    new changeset
  )a

  @impl true
  def id, do: "3.4"

  @impl true
  def description, do: "Detect Type-3 clones — similar functions with minor variations"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: walk all functions, compute shingle fingerprints,
  pairwise compare via Jaccard similarity, report similar pairs above threshold.
  """
  def analyze_project(file_asts) do
    functions =
      file_asts
      |> Enum.flat_map(fn {file, ast} ->
        if AST.test_file?(file) do
          []
        else
          extract_with_fingerprints(file, ast)
        end
      end)
      |> Enum.filter(fn fn_info -> fn_info.size >= @min_node_count end)

    # Pairwise compare. To avoid O(n²) explosion on large projects,
    # we partition by approximate size first (functions of very different sizes
    # can't be similar enough to matter).
    functions
    |> Enum.with_index()
    |> Enum.flat_map(fn {fn_a, i} ->
      functions
      |> Enum.drop(i + 1)
      |> Enum.filter(fn fn_b -> size_compatible?(fn_a.size, fn_b.size) and not_same_pair?(fn_a, fn_b) end)
      |> Enum.map(fn fn_b ->
        sim = jaccard(fn_a.fingerprint, fn_b.fingerprint)
        {fn_a, fn_b, sim}
      end)
      |> Enum.filter(fn {_, _, sim} -> sim >= @similarity_threshold end)
    end)
    |> Enum.sort_by(fn {_, _, sim} -> -sim end)
    |> Enum.take(@max_pairs_to_report)
    |> Enum.map(&build_diagnostic/1)
  end

  defp extract_with_fingerprints(file, ast) do
    fns = AST.extract_functions(ast, :all)

    fns
    |> Enum.reject(fn {name, _arity, _meta, _args, _body} -> name in @ignored_callbacks end)
    |> Enum.map(fn {name, arity, meta, _args, body} ->
      normalized = DuplicatedCode.normalize(body)
      shingles = compute_shingles(normalized)
      size = AST.ast_size(normalized)

      %{
        file: file,
        module: AST.extract_module_name(ast),
        name: name,
        arity: arity,
        line: AST.line(meta),
        fingerprint: shingles,
        size: size,
        normalized_hash: :erlang.phash2(normalized)
      }
    end)
  end

  # Generate shingles: walk the AST in pre-order, collect node "tokens",
  # then create sliding windows of size @shingle_size.
  defp compute_shingles(ast) do
    tokens = collect_tokens(ast, [])

    tokens
    |> Enum.chunk_every(@shingle_size, 1, :discard)
    |> Enum.map(&:erlang.phash2/1)
    |> MapSet.new()
  end

  # Collect a flat list of "tokens" from the AST that represent its structure.
  # Variable references and metadata are normalized away.
  defp collect_tokens(nil, acc), do: acc
  defp collect_tokens([], acc), do: acc

  defp collect_tokens([h | t], acc) do
    acc2 = collect_tokens(h, acc)
    collect_tokens(t, acc2)
  end

  defp collect_tokens({:_VAR, _, _}, acc), do: [:VAR | acc]

  defp collect_tokens({{:., _, [{:__aliases__, _, parts}, fname]}, _, args}, acc) do
    # Module.fn(args) — emit a "module-call" token preserving the call name
    mod_token = {:mcall, parts, fname}
    collect_tokens(args, [mod_token | acc])
  end

  defp collect_tokens({form, _, args}, acc) when is_atom(form) do
    # Local form: emit the form name, then walk args
    collect_tokens(args, [{:f, form} | acc])
  end

  defp collect_tokens({a, b, c}, acc) when is_list(b) do
    acc2 = collect_tokens(a, acc)
    collect_tokens(c, acc2)
  end

  defp collect_tokens({a, b}, acc) do
    acc2 = collect_tokens(a, acc)
    collect_tokens(b, acc2)
  end

  defp collect_tokens(atom, acc) when is_atom(atom), do: [{:a, atom} | acc]
  defp collect_tokens(num, acc) when is_number(num), do: [:NUM | acc]
  defp collect_tokens(bin, acc) when is_binary(bin), do: [:STR | acc]
  defp collect_tokens(_, acc), do: acc

  defp jaccard(set_a, set_b) do
    intersection = MapSet.size(MapSet.intersection(set_a, set_b))
    union = MapSet.size(MapSet.union(set_a, set_b))
    case union do
      0 -> 0.0
      _ -> intersection / union
    end
  end

  # Two functions can only be similar if their sizes are within ~50% of each other
  defp size_compatible?(s1, s2) do
    smaller = min(s1, s2)
    larger = max(s1, s2)
    smaller / larger >= 0.5
  end

  # Skip pairs that are exact duplicates (rule 3.1 catches those)
  defp not_same_pair?(a, b) do
    a.normalized_hash != b.normalized_hash and
      not (a.module == b.module and a.name == b.name and a.arity == b.arity)
  end

  defp build_diagnostic({fn_a, fn_b, sim}) do
    pct = round(sim * 100)
    other = "#{fn_b.module}.#{fn_b.name}/#{fn_b.arity}"

    Diagnostic.info("3.4",
      title: "Similar function (Type-3 clone)",
      message:
        "#{fn_a.name}/#{fn_a.arity} is #{pct}% similar to #{other}",
      why:
        "Type-3 clones are functions that started as copies and then drifted slightly — different variable " <>
          "names, an extra step, a renamed call. They are the most expensive form of duplication: bug fixes " <>
          "have to be re-applied per-copy, the variations gradually disagree, and reading code becomes " <>
          "'compare these two and figure out which differences matter.' Refactoring them early is much cheaper " <>
          "than later.",
      alternatives: [
        Fix.new(
          summary: "Extract a shared function and parameterize the differences",
          detail:
            "Identify what's the same between the two functions and what differs. Pull the common skeleton " <>
              "into a single function, parameterizing the variant pieces (a value, a callback, a step in a " <>
              "pipeline). Replace each call site with a call to the shared function.",
          applies_when: "The differences are localized to a few clear parameters."
        ),
        Fix.new(
          summary: "Use a template + behaviour pattern",
          detail:
            "If the functions share a long skeleton with several variation points, define a behaviour with " <>
              "callbacks for each variation point and have each module implement the callbacks. The skeleton " <>
              "lives once.",
          applies_when: "The functions differ in several places throughout the body."
        ),
        Fix.new(
          summary: "Leave them alone if they're conceptually different",
          detail:
            "Sometimes near-identical functions describe different concepts that happen to have similar " <>
              "shapes (e.g. two parsers with similar token soups). Combining them couples unrelated concepts. " <>
              "Add to the freeze baseline.",
          applies_when: "The duplication is coincidental, not conceptual."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#3.4"],
      context: %{
        function: "#{fn_a.module}.#{fn_a.name}/#{fn_a.arity}",
        similar_to: other,
        similarity: pct
      },
      file: fn_a.file,
      line: fn_a.line
    )
  end

end
