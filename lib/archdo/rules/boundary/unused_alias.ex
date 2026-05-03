defmodule Archdo.Rules.Boundary.UnusedAlias do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.27"

  @impl true
  def description, do: "Alias is declared but the short name is never referenced"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_unused_aliases(file, ast)
    end
  end

  defp find_unused_aliases(file, ast) do
    aliases = extract_aliases(ast)
    short_name_refs = collect_short_name_references(ast)

    Enum.flat_map(aliases, fn {short_name, full_parts, meta} ->
      # Count how many times the short name appears as the first segment
      # of a module reference (e.g. User in User.get/1 or %User{}).
      # The alias declaration itself uses the full path (MyApp.Accounts.User),
      # where the first segment is NOT the short name, so it does not
      # contribute to this count.
      ref_count = Map.get(short_name_refs, short_name, 0)

      case ref_count == 0 do
        true ->
          full_name = Enum.map_join(full_parts, ".", &atom_to_string/1)
          [build_diagnostic(file, AST.line(meta), short_name, full_name)]

        false ->
          []
      end
    end)
  end

  defp extract_aliases(ast) do
    {_, aliases} =
      Macro.prewalk(ast, [], fn
        # Simple alias: alias Foo.Bar
        {:alias, meta, [{:__aliases__, _, parts}]} = node, acc when is_list(parts) ->
          {node, accumulate_simple_alias(skip_alias?(parts), parts, meta, acc)}

        # Alias with :as option: alias Foo.Bar, as: Baz
        {:alias, meta, [{:__aliases__, _, parts}, opts]} = node, acc
        when is_list(parts) and is_list(opts) ->
          {node, accumulate_as_alias(skip_multi_alias?(opts), opts, parts, meta, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(aliases)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the skip-alias and short-name shape booleans.
  defp accumulate_simple_alias(true, _parts, _meta, acc), do: acc

  defp accumulate_simple_alias(false, parts, meta, acc) do
    short = List.last(parts)
    [{atom_to_string(short), parts, meta} | acc]
  end

  defp accumulate_as_alias(true, _opts, _parts, _meta, acc), do: acc

  defp accumulate_as_alias(false, opts, parts, meta, acc) do
    record_as_alias(extract_as_name(opts, parts), parts, meta, acc)
  end

  defp record_as_alias(nil, _parts, _meta, acc), do: acc
  defp record_as_alias(name, parts, meta, acc), do: [{name, parts, meta} | acc]

  defp extract_as_name(opts, parts) do
    # Handle both bare :as and literal_encoder wrapped {:__block__, _, [:as]}
    as_value =
      Enum.find_value(opts, fn
        {{:__block__, _, [:as]}, val} -> val
        {:as, val} -> val
        _ -> nil
      end)

    case as_value do
      {:__aliases__, _, [as_name]} -> atom_to_string(as_name)
      nil -> atom_to_string(List.last(parts))
      _ -> nil
    end
  end

  # Skip multi-alias syntax like alias Foo.{Bar, Baz}
  defp skip_multi_alias?(opts) do
    Keyword.has_key?(opts, :do)
  end

  defp skip_alias?(parts) do
    case List.last(parts) do
      # Multi-alias: alias Foo.{Bar, Baz} — the last part won't be a simple atom
      {:__block__, _, _} -> true
      _ -> false
    end
  end

  # Collect references where the short (aliased) name appears as the first
  # segment of a module reference that is NOT a full-path alias declaration.
  # When you write `User.get(id)`, the AST has `{:__aliases__, _, [:User]}`.
  # When the alias is `alias MyApp.Accounts.User`, the AST has
  # `{:__aliases__, _, [:MyApp, :Accounts, :User]}`, where the first segment
  # is :MyApp — so the alias declaration does not pollute the count.
  #
  # We collect all alias declaration line numbers first, then walk the AST
  # counting first-segments of __aliases__ nodes not on those lines.
  defp collect_short_name_references(ast) do
    alias_lines = collect_alias_lines(ast)

    {_, refs} =
      Macro.prewalk(ast, %{}, fn
        {:__aliases__, meta, [first | _]} = node, acc when is_atom(first) ->
          line = Keyword.get(meta, :line, 0)

          case MapSet.member?(alias_lines, line) do
            true ->
              {node, acc}

            false ->
              name = Atom.to_string(first)
              {node, Map.update(acc, name, 1, &(&1 + 1))}
          end

        node, acc ->
          {node, acc}
      end)

    refs
  end

  defp collect_alias_lines(ast) do
    {_, lines} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:alias, meta, _} = node, acc ->
          {node, MapSet.put(acc, Keyword.get(meta, :line, 0))}

        node, acc ->
          {node, acc}
      end)

    lines
  end

  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_to_string({:__block__, _, [atom]}) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_to_string(_), do: ""

  defp build_diagnostic(file, line, short_name, full_name) do
    Diagnostic.info("4.27",
      title: "Unused alias",
      message: "alias #{full_name} (as #{short_name}) is never referenced",
      why:
        "An unused alias adds noise to the module header and suggests a " <>
          "dependency that doesn't exist. It may be a leftover from a " <>
          "refactoring that removed the code using it.",
      alternatives: [
        Fix.new(
          summary: "Remove the unused alias",
          detail: "Delete the `alias #{full_name}` line.",
          applies_when: "The alias is genuinely unused."
        ),
        Fix.new(
          summary: "Use the aliased module",
          detail:
            "If the alias was added intentionally, add the code that references #{short_name}.",
          applies_when: "The code using this alias was accidentally removed."
        )
      ],
      file: file,
      line: line
    )
  end
end
