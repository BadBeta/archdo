defmodule Archdo.Rules.Module.ShadowedClause do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.54"

  @impl true
  def description,
    do: "Broader pattern before a specific one — later clause is shadowed and may never match"

  # Clauses farther apart than this are likely in different compile-time branches
  @max_clause_distance 50

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_shadowed(file, ast)
    end
  end

  defp find_shadowed(file, ast) do
    fn_shadows = find_shadowed_function_clauses(file, ast)
    case_shadows = find_shadowed_case_clauses(file, ast)
    fn_shadows ++ case_shadows
  end

  # ================================================================
  # Multi-clause function heads: def f(broad) before def f(specific)
  # ================================================================

  defp find_shadowed_function_clauses(file, ast) do
    # Each defmodule is an independent scope: a `def foo` in `MyApp.Inner`
    # does not shadow `def foo` in the outer `MyApp`. Process each module
    # body separately so cross-module same-named defs don't conflate.
    ast
    |> collect_module_bodies([])
    |> Enum.flat_map(fn module_body ->
      module_body
      |> extract_defs_in_scope([])
      |> Enum.reverse()
      |> Enum.group_by(fn {name, arity, _meta, _args, _guards} -> {name, arity} end)
      |> Enum.flat_map(fn {_key, clauses} -> check_clause_ordering(file, clauses) end)
    end)
  end

  # Walk the AST and collect the body of every `defmodule` (top-level and
  # nested). Each body is analyzed for shadowing in isolation.
  defp collect_module_bodies({:defmodule, _, [_alias, [do: body]]}, acc) do
    # Add THIS module's body, then recurse INTO it to find nested defmodules.
    [body | collect_module_bodies(body, acc)]
  end

  defp collect_module_bodies({_form, _meta, args}, acc) when is_list(args) do
    Enum.reduce(args, acc, &collect_module_bodies/2)
  end

  defp collect_module_bodies(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_module_bodies/2)
  end

  defp collect_module_bodies({a, b}, acc) do
    acc |> then(&collect_module_bodies(a, &1)) |> then(&collect_module_bodies(b, &1))
  end

  defp collect_module_bodies(_, acc), do: acc

  # Extract def/defp at the current module body's scope, returning
  # {name, arity, meta, args, guards} per clause.
  #
  # Scope-aware: does NOT descend into nodes that introduce a separate scope
  # or a compile-time-mutually-exclusive branch:
  #   - `defimpl Protocol, for: Type do ... end` — separate impl module per :for
  #   - `defprotocol`, nested `defmodule` — separate modules (analyzed in their
  #     own pass via `collect_module_bodies/2`)
  #   - `if`, `unless`, `case`, `cond` — only one branch compiles, so two `def`s
  #     across branches are alternatives, not shadowing siblings
  #   - `quote do ... end` — macro-generated AST, not direct module content
  #
  # Without these stops, the rule false-positives on identical function names
  # across `defimpl`s for different types, across `if Mix.env()` branches, and
  # across nested defmodules in the same file (BUG-5 from hexpm field test).

  defp extract_defs_in_scope(
         {kind, meta, [{:when, _, [{name, _, args} | guards]}, _body]},
         acc
       )
       when kind in [:def, :defp] and is_atom(name) and is_list(args) do
    [{name, length(args), meta, args, guards} | acc]
  end

  defp extract_defs_in_scope({kind, meta, [{name, _, args}, _body]}, acc)
       when kind in [:def, :defp] and is_atom(name) and is_list(args) do
    [{name, length(args), meta, args, nil} | acc]
  end

  # Scope barriers — do not descend.
  defp extract_defs_in_scope({:defmodule, _, _}, acc), do: acc
  defp extract_defs_in_scope({:defimpl, _, _}, acc), do: acc
  defp extract_defs_in_scope({:defprotocol, _, _}, acc), do: acc
  defp extract_defs_in_scope({:quote, _, _}, acc), do: acc
  defp extract_defs_in_scope({:if, _, _}, acc), do: acc
  defp extract_defs_in_scope({:unless, _, _}, acc), do: acc
  defp extract_defs_in_scope({:case, _, _}, acc), do: acc
  defp extract_defs_in_scope({:cond, _, _}, acc), do: acc

  defp extract_defs_in_scope({_form, _meta, args}, acc) when is_list(args) do
    Enum.reduce(args, acc, &extract_defs_in_scope/2)
  end

  defp extract_defs_in_scope(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &extract_defs_in_scope/2)
  end

  defp extract_defs_in_scope({a, b}, acc) do
    acc |> then(&extract_defs_in_scope(a, &1)) |> then(&extract_defs_in_scope(b, &1))
  end

  defp extract_defs_in_scope(_, acc), do: acc

  defp check_clause_ordering(_file, clauses) when length(clauses) < 2, do: []

  defp check_clause_ordering(file, clauses) do
    patterns =
      Enum.map(clauses, fn {_name, _arity, meta, args, guards} ->
        {meta, args, guards}
      end)

    patterns
    |> Enum.with_index()
    |> Enum.flat_map(&compare_to_later_patterns(&1, patterns, file))
  end

  defp compare_to_later_patterns(
         {{earlier_meta, earlier_args, earlier_guards}, i},
         patterns,
         file
       ) do
    earlier_line = AST.line(earlier_meta)

    patterns
    |> Enum.drop(i + 1)
    |> Enum.flat_map(&shadowing_for_pair(&1, earlier_line, earlier_args, earlier_guards, file))
  end

  defp shadowing_for_pair(
         {later_meta, later_args, later_guards},
         earlier_line,
         earlier_args,
         earlier_guards,
         file
       ) do
    later_line = AST.line(later_meta)
    distance_close? = abs(later_line - earlier_line) <= @max_clause_distance

    diag_for_close_clauses(
      distance_close?,
      file,
      earlier_line,
      later_line,
      earlier_args,
      earlier_guards,
      later_args,
      later_guards
    )
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the proximity boolean, then on guard relationship.
  defp diag_for_close_clauses(false, _file, _el, _ll, _ea, _eg, _la, _lg), do: []

  defp diag_for_close_clauses(
         true,
         file,
         earlier_line,
         later_line,
         earlier_args,
         earlier_guards,
         later_args,
         later_guards
       ) do
    classify_guards(earlier_guards, later_guards)
    |> emit_shadow_diag(file, earlier_line, later_line, earlier_args, later_args)
  end

  defp classify_guards(earlier_guards, later_guards) do
    cond do
      guards_are_disjoint?(earlier_guards, later_guards) -> :disjoint
      earlier_guards != nil -> :earlier_has_guard
      true -> :pattern_only
    end
  end

  defp emit_shadow_diag(:disjoint, _file, _el, _ll, _ea, _la), do: []
  defp emit_shadow_diag(:earlier_has_guard, _file, _el, _ll, _ea, _la), do: []

  defp emit_shadow_diag(:pattern_only, file, earlier_line, later_line, earlier_args, later_args) do
    diag_for_pattern_shadow(
      pattern_shadows?(earlier_args, later_args),
      file,
      earlier_line,
      later_line
    )
  end

  defp diag_for_pattern_shadow({:shadowed, reason}, file, earlier_line, later_line),
    do: [build_fn_diagnostic(file, earlier_line, later_line, reason)]

  defp diag_for_pattern_shadow(:ok, _file, _el, _ll), do: []

  # ================================================================
  # case clauses: case x do broad -> ... ; specific -> ... end
  # ================================================================

  defp find_shadowed_case_clauses(file, ast) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        {:case, _meta, [_expr, [do: clauses]]} = node, acc when is_list(clauses) ->
          patterns =
            Enum.map(clauses, fn
              {:->, meta, [[pattern | _guards], _body]} -> {meta, pattern}
              {:->, meta, [[], _body]} -> {meta, {:_, [], nil}}
            end)

          new_diags = check_case_pattern_ordering(file, patterns)
          {node, new_diags ++ acc}

        node, acc ->
          {node, acc}
      end)

    diagnostics
  end

  defp check_case_pattern_ordering(_file, patterns) when length(patterns) < 2, do: []

  defp check_case_pattern_ordering(file, patterns) do
    patterns
    |> Enum.with_index()
    |> Enum.flat_map(&compare_case_pair(&1, patterns, file))
  end

  defp compare_case_pair({{earlier_meta, earlier_pat}, i}, patterns, file) do
    patterns
    |> Enum.drop(i + 1)
    |> Enum.flat_map(&case_pair_diag(&1, earlier_meta, earlier_pat, file))
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the result of single_pattern_shadows?
  defp case_pair_diag({later_meta, later_pat}, earlier_meta, earlier_pat, file) do
    diag_for_case_shadow(
      single_pattern_shadows?(earlier_pat, later_pat),
      file,
      earlier_meta,
      later_meta
    )
  end

  defp diag_for_case_shadow({:shadowed, reason}, file, earlier_meta, later_meta),
    do: [build_case_diagnostic(file, AST.line(earlier_meta), AST.line(later_meta), reason)]

  defp diag_for_case_shadow(:ok, _file, _em, _lm), do: []

  # ================================================================
  # Pattern subsumption checks
  # ================================================================

  # For function heads: check if the earlier arg list shadows the later one.
  # Both are lists of patterns (one per parameter).
  defp pattern_shadows?(earlier_args, later_args)
       when length(earlier_args) != length(later_args),
       do: :ok

  defp pattern_shadows?(earlier_args, later_args) do
    # If the earlier clause reuses a variable name across params (e.g., `same, same`),
    # it's NOT a catch-all — it constrains both params to be equal. Skip these.
    case has_repeated_variable?(earlier_args) do
      true -> :ok
      false -> do_pattern_shadows?(earlier_args, later_args)
    end
  end

  defp do_pattern_shadows?(earlier_args, later_args) do
    # ALL params in the earlier clause must be at least as broad as the later ones
    pairs = Enum.zip(earlier_args, later_args)

    results =
      Enum.map(pairs, fn {earlier, later} ->
        single_pattern_shadows?(earlier, later)
      end)

    case Enum.all?(results, fn
           {:shadowed, _} -> true
           :ok -> false
         end) do
      true ->
        # Pick the most informative reason
        reason =
          results
          |> Enum.find_value(fn
            {:shadowed, r} -> r
            :ok -> nil
          end)

        {:shadowed, reason}

      false ->
        :ok
    end
  end

  # Single pattern: does `earlier` match a superset of what `later` matches?
  # If yes, `later` is shadowed.

  # Catch-all (_, variable) shadows everything — including other catch-alls
  defp single_pattern_shadows?(earlier, later) do
    case catch_all_check?(earlier) do
      true -> {:shadowed, :catch_all_before_specific}
      false -> single_pattern_shadows_specific?(earlier, later)
    end
  end

  # Same literal → same specificity, not shadowed
  defp single_pattern_shadows_specific?(same, same), do: :ok

  # %{} (empty map pattern) shadows %{key: _} and %Struct{}
  defp single_pattern_shadows_specific?({:%{}, _, []}, {:%{}, _, fields}) when fields != [] do
    {:shadowed, :empty_map_before_keyed_map}
  end

  defp single_pattern_shadows_specific?({:%{}, _, []}, {:%, _, _}) do
    {:shadowed, :empty_map_before_struct}
  end

  # %{key: _} shadows %{key: :specific_value}
  defp single_pattern_shadows_specific?({:%{}, _, earlier_fields}, {:%{}, _, later_fields})
       when is_list(earlier_fields) and is_list(later_fields) do
    check_map_field_shadowing(earlier_fields, later_fields)
  end

  # {_, _} (tuple of catch-alls) shadows {specific, _}
  defp single_pattern_shadows_specific?({:{}, _, earlier_elems}, {:{}, _, later_elems})
       when length(earlier_elems) == length(later_elems) do
    check_tuple_shadowing(earlier_elems, later_elems)
  end

  # 2-tuple shorthand: {a, b} in AST is just {a, b} not {:{}, _, [a, b]}
  defp single_pattern_shadows_specific?({ea, eb}, {la, lb})
       when is_tuple(ea) and is_tuple(la) do
    check_tuple_shadowing([ea, eb], [la, lb])
  end

  # Tagged tuple: {:ok, _} vs {:ok, %Struct{}}
  defp single_pattern_shadows_specific?({tag_e, val_e}, {tag_l, val_l})
       when is_atom(tag_e) or (is_tuple(tag_e) and elem(tag_e, 0) == :__block__) do
    case tags_equal?(tag_e, tag_l) do
      true -> single_pattern_shadows?(val_e, val_l)
      false -> :ok
    end
  end

  # List: [_ | _] shadows [specific | _]
  defp single_pattern_shadows_specific?([{:|, _, [eh, et]}], [{:|, _, [lh, lt]}]) do
    case {single_pattern_shadows?(eh, lh), single_pattern_shadows?(et, lt)} do
      {{:shadowed, _}, {:shadowed, _}} -> {:shadowed, :broad_list_before_specific}
      _ -> :ok
    end
  end

  # Bare atom/integer/string — different literals don't shadow each other
  defp single_pattern_shadows_specific?(e, l) when is_atom(e) and is_atom(l), do: :ok
  defp single_pattern_shadows_specific?(e, l) when is_integer(e) and is_integer(l), do: :ok
  defp single_pattern_shadows_specific?(e, l) when is_binary(e) and is_binary(l), do: :ok

  # Default: can't determine — assume no shadow
  defp single_pattern_shadows_specific?(_earlier, _later), do: :ok

  # ================================================================
  # Map field shadowing: %{a: _} before %{a: :specific, b: _}
  # Earlier map pattern shadows later if:
  #   - earlier has FEWER or EQUAL keys (broader match)
  #   - every key in earlier also appears in later
  #   - each value in earlier is at least as broad as in later
  # ================================================================

  defp check_map_field_shadowing(earlier_fields, later_fields) do
    earlier_keys = MapSet.new(Enum.map(earlier_fields, &field_key/1))
    later_keys = MapSet.new(Enum.map(later_fields, &field_key/1))

    # Every key in earlier must be in later (earlier is a subset of required keys)
    map_shadow_for_subset(
      MapSet.subset?(earlier_keys, later_keys),
      earlier_fields,
      later_fields,
      earlier_keys,
      later_keys
    )
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the subset boolean and the all_shadow? boolean.
  defp map_shadow_for_subset(false, _ef, _lf, _ek, _lk), do: :ok

  defp map_shadow_for_subset(true, earlier_fields, later_fields, earlier_keys, later_keys) do
    # Check that each shared field value in earlier is at least as broad
    earlier_map = Map.new(earlier_fields, fn {k, v} -> {field_key(k), v} end)
    later_map = Map.new(later_fields, fn {k, v} -> {field_key(k), v} end)

    all_shadow? = Enum.all?(earlier_keys, &field_value_shadows?(&1, earlier_map, later_map))

    map_shadow_verdict(all_shadow? and MapSet.size(earlier_keys) <= MapSet.size(later_keys))
  end

  defp field_value_shadows?(key, earlier_map, later_map) do
    shared_field_dispatch(Map.fetch(earlier_map, key), Map.fetch(later_map, key))
  end

  defp shared_field_dispatch({:ok, ev}, {:ok, lv}) do
    # Earlier value shadows later if earlier is a catch-all or same value
    catch_all_check?(ev) or match?({:shadowed, _}, single_pattern_shadows?(ev, lv))
  end

  defp shared_field_dispatch(_ef, _lf), do: false

  defp map_shadow_verdict(true), do: {:shadowed, :broad_map_before_specific}
  defp map_shadow_verdict(false), do: :ok

  defp field_key({key, _value}), do: key
  defp field_key(key), do: key

  # ================================================================
  # Tuple element shadowing
  # ================================================================

  defp check_tuple_shadowing(earlier_elems, later_elems) do
    results =
      Enum.zip(earlier_elems, later_elems)
      |> Enum.map(fn {e, l} -> single_pattern_shadows?(e, l) end)

    case Enum.all?(results, &match?({:shadowed, _}, &1)) do
      true -> {:shadowed, :broad_tuple_before_specific}
      false -> :ok
    end
  end

  # ================================================================
  # Catch-all detection
  # ================================================================

  # `_`, `_name`, or bare variable (not pinned, not destructured, not special form)
  defp catch_all_check?({:_, _, _}), do: true

  defp catch_all_check?({name, _, context})
       when is_atom(name) and is_atom(context) do
    # Special AST nodes that look like 3-tuples but aren't variables
    name not in [:%, :%{}, :{}, :__block__, :^, :<<>>, :|>, :., :@, :&, :fn, :when, :|]
  end

  defp catch_all_check?(_), do: false

  # ================================================================
  # Helpers
  # ================================================================

  # ================================================================
  # Guard disjointness — do two guards check non-overlapping types?
  # ================================================================

  # Type-check guards that are mutually exclusive
  @type_guards [
    :is_atom,
    :is_binary,
    :is_bitstring,
    :is_boolean,
    :is_float,
    :is_function,
    :is_integer,
    :is_list,
    :is_map,
    :is_nil,
    :is_number,
    :is_pid,
    :is_port,
    :is_reference,
    :is_tuple
  ]

  # If both clauses have guards, they likely differentiate —
  # only flag when we can prove they overlap. Conservatively: if both have
  # ANY guard, consider them potentially disjoint unless proven otherwise.
  # If either has no guard, the unguarded one matches everything.
  defp guards_are_disjoint?(nil, _), do: false
  defp guards_are_disjoint?(_, nil), do: false

  defp guards_are_disjoint?(earlier_guards, later_guards) do
    earlier_types = extract_type_guards(earlier_guards)
    later_types = extract_type_guards(later_guards)

    case {earlier_types, later_types} do
      # Both have type guards — check if they're provably disjoint types
      {[_ | _], [_ | _]} ->
        MapSet.disjoint?(MapSet.new(earlier_types), MapSet.new(later_types))

      # Both have guards but not all are type guards — conservatively assume
      # the guards differentiate (range checks, value comparisons, etc.)
      _ ->
        true
    end
  end

  # Extract type-check guard function names from a guard expression
  defp extract_type_guards(guards) when is_list(guards) do
    Enum.flat_map(guards, &extract_type_guards/1)
  end

  defp extract_type_guards({guard_fn, _, _}) when guard_fn in @type_guards do
    [guard_fn]
  end

  # `when x in [...]` — membership guard, acts like multiple literals
  defp extract_type_guards({:in, _, _}), do: [:in_guard]

  # `when guard1 and guard2` — both must hold
  defp extract_type_guards({:and, _, [left, right]}) do
    Enum.flat_map([left, right], &extract_type_guards/1)
  end

  # `when guard1 or guard2` — either holds (broadens the match)
  defp extract_type_guards({:or, _, [left, right]}) do
    Enum.flat_map([left, right], &extract_type_guards/1)
  end

  defp extract_type_guards(_), do: []

  # A clause like `def f(x, x)` uses variable rebinding to assert equality.
  # This is NOT a catch-all — it constrains both params to be equal.
  defp has_repeated_variable?(args) do
    var_names =
      args
      |> Enum.filter(fn
        {name, _, ctx} when is_atom(name) and is_atom(ctx) -> true
        _ -> false
      end)
      |> Enum.map(fn {name, _, _} -> name end)
      |> Enum.reject(&(&1 == :_))

    length(var_names) != length(Enum.uniq(var_names))
  end

  # Compare tag atoms, accounting for literal_encoder wrapping
  defp tags_equal?(a, b) when a == b, do: true
  defp tags_equal?({:__block__, _, [a]}, b) when a == b, do: true
  defp tags_equal?(a, {:__block__, _, [b]}) when a == b, do: true
  defp tags_equal?({:__block__, _, [a]}, {:__block__, _, [b]}) when a == b, do: true
  defp tags_equal?(_, _), do: false

  # ================================================================
  # Diagnostics
  # ================================================================

  defp build_fn_diagnostic(file, broad_line, specific_line, reason) do
    Diagnostic.warning("6.54",
      title: "Shadowed function clause",
      message:
        "Clause at line #{broad_line} has a broader pattern that shadows " <>
          "the more specific clause at line #{specific_line} — #{reason_text(reason)}",
      why:
        "Elixir matches function clauses top-to-bottom. When an earlier clause's pattern " <>
          "is a superset of a later clause's pattern (without a distinguishing guard), " <>
          "the later clause can never execute. This is usually a clause ordering mistake. " <>
          "Place the most specific patterns first, general/fallback patterns last.",
      alternatives: [
        Fix.new(
          summary: "Move the specific clause before the broader one",
          detail:
            "Reorder clauses so the more specific pattern (line #{specific_line}) " <>
              "comes before the broader one (line #{broad_line}).",
          applies_when: "The specific clause handles a case the broader one should not."
        ),
        Fix.new(
          summary: "Add a guard to the broader clause",
          detail:
            "If the broader clause should only match certain cases, add a `when` guard " <>
              "to narrow its match so it doesn't shadow the specific clause.",
          applies_when: "Both clauses are intentional and should match different subsets."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.54"],
      context: %{broad_line: broad_line, specific_line: specific_line, reason: reason},
      file: file,
      line: specific_line
    )
  end

  defp build_case_diagnostic(file, broad_line, specific_line, reason) do
    Diagnostic.warning("6.54",
      title: "Shadowed case clause",
      message:
        "Case clause at line #{broad_line} shadows the more specific clause at " <>
          "line #{specific_line} — #{reason_text(reason)}",
      why:
        "case matches clauses top-to-bottom. A broader pattern before a specific one " <>
          "means the specific one never executes. Reorder: specific patterns first, " <>
          "catch-all/broad patterns last.",
      alternatives: [
        Fix.new(
          summary: "Reorder case clauses: specific before broad",
          detail:
            "Move the clause at line #{specific_line} above the clause at line #{broad_line}.",
          applies_when: "The specific clause handles a distinct case."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.54"],
      context: %{broad_line: broad_line, specific_line: specific_line, reason: reason},
      file: file,
      line: specific_line
    )
  end

  defp reason_text(:catch_all_before_specific), do: "catch-all pattern before specific match"
  defp reason_text(:empty_map_before_keyed_map), do: "%{} matches any map, shadows %{key: _}"
  defp reason_text(:empty_map_before_struct), do: "%{} matches any map, shadows %Struct{}"

  defp reason_text(:broad_map_before_specific),
    do: "map with fewer key constraints shadows one with more"

  defp reason_text(:broad_tuple_before_specific),
    do: "tuple with broader elements shadows specific tuple"

  defp reason_text(:broad_list_before_specific),
    do: "list with broader head/tail shadows specific list"

  defp reason_text(reason), do: "#{reason}"
end
