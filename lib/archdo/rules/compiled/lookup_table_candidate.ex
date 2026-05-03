defmodule Archdo.Rules.Compiled.LookupTableCandidate do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled

  @impl true
  def id, do: "6.31"

  @impl true
  def description,
    do: "Function is a pure literal-to-literal mapping — replace with a lookup table"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  # Minimum clauses to consider — 2-clause functions aren't worth converting
  @min_clauses 3

  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    case Compiled.beam_dir(graph) do
      beam_dir when is_binary(beam_dir) -> scan_beam_dir(beam_dir)
      _ -> []
    end
  end

  defp scan_beam_dir(beam_dir) do
    beam_dir
    |> Path.join("Elixir.*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(fn beam_path ->
      charlist = to_charlist(beam_path)

      case :beam_lib.chunks(charlist, [:abstract_code]) do
        {:ok, {mod, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
          exports = Compiled.collect_exports_from_forms(forms)
          find_lookup_candidates(mod, forms, exports)

        _ ->
          []
      end
    end)
  end

  defp find_lookup_candidates(mod, forms, exports) do
    Enum.flat_map(forms, fn
      {:function, _line, name, arity, clauses}
      when name not in [:__info__, :module_info] ->
        case check_lookup_table(name, arity, clauses, exports) do
          nil -> []
          result -> [build_diagnostic(mod, result)]
        end

      _ ->
        []
    end)
  end

  # Check if a function is a pure literal mapping
  defp check_lookup_table(name, arity, clauses, exports) do
    # Must have enough clauses to be worth converting
    mapping_clauses = Enum.filter(clauses, &literal_mapping_clause?/1)
    total = length(clauses)
    mapping_count = length(mapping_clauses)

    # Need at least @min_clauses mapping clauses
    # Allow a catch-all clause (last clause may not be a literal mapping)
    case mapping_count >= @min_clauses and mapping_count >= total - 1 do
      true ->
        mappings = extract_mappings(mapping_clauses)
        has_catch_all = mapping_count < total
        exported = MapSet.member?(exports, {name, arity})

        %{
          name: name,
          arity: arity,
          exported: exported,
          mappings: mappings,
          clause_count: total,
          mapping_count: mapping_count,
          has_catch_all: has_catch_all
        }

      false ->
        # Also check for a single-clause function with a case that's a lookup
        case total == 1 do
          true -> check_case_lookup(name, arity, hd(clauses), exports)
          false -> nil
        end
    end
  end

  # A clause is a literal mapping if:
  # - All arguments are literal patterns (atom, integer, string, tuple of literals)
  # - No guards
  # - The body is a literal value
  defp literal_mapping_clause?({:clause, _, args, guards, body}) do
    guards == [] and
      Enum.all?(args, &literal_pattern?/1) and
      literal_body?(body)
  end

  defp literal_pattern?({:atom, _, _}), do: true
  defp literal_pattern?({:integer, _, _}), do: true
  defp literal_pattern?({:float, _, _}), do: true
  defp literal_pattern?({:string, _, _}), do: true

  defp literal_pattern?({:bin, _, elements}) do
    Enum.all?(elements, fn
      {:bin_element, _, {:string, _, _}, _, _} -> true
      _ -> false
    end)
  end

  defp literal_pattern?({:tuple, _, elements}) do
    Enum.all?(elements, &literal_pattern?/1)
  end

  defp literal_pattern?({:cons, _, head, tail}) do
    literal_pattern?(head) and literal_pattern?(tail)
  end

  defp literal_pattern?({nil, _}), do: true
  defp literal_pattern?(_), do: false

  defp literal_body?(body) do
    case List.last(body) do
      nil -> false
      last -> literal_value?(last)
    end
  end

  defp literal_value?({:atom, _, _}), do: true
  defp literal_value?({:integer, _, _}), do: true
  defp literal_value?({:float, _, _}), do: true
  defp literal_value?({:string, _, _}), do: true

  defp literal_value?({:bin, _, elements}) do
    Enum.all?(elements, fn
      {:bin_element, _, {:string, _, _}, _, _} -> true
      _ -> false
    end)
  end

  defp literal_value?({:tuple, _, elements}) do
    Enum.all?(elements, &literal_value?/1)
  end

  defp literal_value?({:cons, _, head, tail}) do
    literal_value?(head) and literal_value?(tail)
  end

  defp literal_value?({nil, _}), do: true

  defp literal_value?({:map, _, fields}) do
    Enum.all?(fields, fn
      {:map_field_assoc, _, k, v} -> literal_value?(k) and literal_value?(v)
      {:map_field_exact, _, k, v} -> literal_value?(k) and literal_value?(v)
      _ -> false
    end)
  end

  defp literal_value?(_), do: false

  # Check if a single-clause function body is a case statement that's a lookup
  defp check_case_lookup(name, arity, {:clause, _, _args, _guards, body}, exports) do
    case List.last(body) do
      {:case, _, _expr, case_clauses} ->
        mapping_clauses = Enum.filter(case_clauses, &literal_mapping_clause?/1)
        total = length(case_clauses)
        mapping_count = length(mapping_clauses)

        case mapping_count >= @min_clauses and mapping_count >= total - 1 do
          true ->
            mappings = extract_mappings(mapping_clauses)
            has_catch_all = mapping_count < total
            exported = MapSet.member?(exports, {name, arity})

            %{
              name: name,
              arity: arity,
              exported: exported,
              mappings: mappings,
              clause_count: total,
              mapping_count: mapping_count,
              has_catch_all: has_catch_all,
              via_case: true
            }

          false ->
            nil
        end

      _ ->
        nil
    end
  end

  defp extract_mappings(clauses) do
    Enum.map(clauses, fn {:clause, _, args, _, body} ->
      key = format_literal_list(args)
      value = format_literal(List.last(body))
      {key, value}
    end)
  end

  defp format_literal_list(args) do
    Enum.map_join(args, ", ", &format_literal/1)
  end

  defp format_literal({:atom, _, val}), do: ":#{val}"
  defp format_literal({:integer, _, val}), do: "#{val}"
  defp format_literal({:float, _, val}), do: "#{val}"

  defp format_literal({:string, _, charlist}), do: "\"#{to_string(charlist)}\""

  defp format_literal({:bin, _, [{:bin_element, _, {:string, _, charlist}, _, _}]}),
    do: "\"#{to_string(charlist)}\""

  defp format_literal({:tuple, _, elements}),
    do: "{#{Enum.map_join(elements, ", ", &format_literal/1)}}"

  defp format_literal({nil, _}), do: "[]"

  defp format_literal({:cons, _, _, _}), do: "[...]"
  defp format_literal({:map, _, _}), do: "%{...}"
  defp format_literal(_), do: "?"

  defp build_diagnostic(mod, result) do
    mod_name = AST.module_name(mod)
    via = if Map.get(result, :via_case), do: " (via case statement)", else: ""

    sample =
      result.mappings
      |> Enum.take(5)
      |> Enum.map_join(", ", fn {k, v} -> "#{k} → #{v}" end)

    more =
      case length(result.mappings) > 5 do
        true -> " + #{length(result.mappings) - 5} more"
        false -> ""
      end

    map_suggestion = build_map_suggestion(mod_name, result)

    Diagnostic.info("6.31",
      title: "Lookup table candidate",
      message:
        "#{mod_name}.#{result.name}/#{result.arity} is a pure literal mapping" <>
          " (#{result.mapping_count} entries#{via}): #{sample}#{more}",
      why:
        "This function maps literal values to literal values with no computation — " <>
          "it is functionally equivalent to a Map lookup. Replacing it with a module " <>
          "attribute map is more concise, self-documenting, and can be more efficient " <>
          "(O(log n) map lookup vs O(n) clause matching for large tables). " <>
          "It also makes the data extractable for documentation, serialization, or " <>
          "runtime introspection.",
      alternatives: [
        Fix.new(
          summary: "Replace with a module attribute map",
          detail: map_suggestion,
          applies_when: "The mapping is a fixed data table."
        ),
        Fix.new(
          summary: "Keep as multi-clause if intentional",
          detail:
            "Multi-clause functions are idiomatic Elixir for small dispatch tables. " <>
              "Keep them if the clauses may gain guards or complex logic later, or if " <>
              "the function is part of a pattern-matching API.",
          applies_when: "The clauses are likely to grow beyond simple literal mapping."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.31"],
      context: %{
        module: mod_name,
        function: "#{result.name}/#{result.arity}",
        mapping_count: result.mapping_count,
        has_catch_all: result.has_catch_all,
        exported: result.exported
      },
      file: "lib",
      line: 0
    )
  end

  defp build_map_suggestion(mod_name, result) do
    entries =
      result.mappings
      |> Enum.take(5)
      |> Enum.map_join(", ", fn {k, v} -> "#{k} => #{v}" end)

    more =
      case length(result.mappings) > 5 do
        true -> ", ..."
        false -> ""
      end

    catch_all_line =
      case result.has_catch_all do
        true -> "\n  def #{result.name}(key), do: Map.get(@#{result.name}_map, key)"
        false -> "\n  def #{result.name}(key), do: Map.fetch!(@#{result.name}_map, key)"
      end

    "In #{mod_name}:\n" <>
      "  @#{result.name}_map %{#{entries}#{more}}" <>
      catch_all_line
  end
end
