defmodule Archdo.Rules.Module.RaiseInNonBang do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.10"

  @impl true
  def description, do: "Non-bang functions should return ok/error tuples, not raise"

  # Functions where raising is idiomatic (setup, validation, compile-time, framework callbacks)
  @raise_ok_contexts ~w(validate! assert! ensure! check! start! stop! init)a

  # Framework callbacks where raising is "let it crash" by convention
  @framework_callbacks ~w(
    handle_init handle_setup handle_playing handle_terminate
    handle_pad_added handle_pad_removed handle_child_notification
    handle_parent_notification handle_element_start_of_stream
    handle_element_end_of_stream handle_tick handle_stream_format
    handle_event handle_buffer handle_process handle_demand
    handle_info handle_call handle_cast handle_continue
    handle_set_up_tracks handle_input_tracks_negotiated
    handle_output_tracks_negotiated
    terminate code_change format_status callback_mode
  )a

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_raises_in_non_bang(file, ast)
    end
  end

  defp find_raises_in_non_bang(file, ast) do
    fns = AST.extract_functions(ast, :public)
    impl_set = impl_marked_functions(ast)
    defimpl_set = defimpl_callbacks(ast)

    fns
    |> Enum.reject(fn {name, arity, _meta, _args, _body} ->
      not is_atom(name) or bang_function?(name) or name in @raise_ok_contexts or
        name in @framework_callbacks or
        # Skip behaviour callbacks: a function annotated with `@impl true` or
        # `@impl SomeBehaviour` has a fixed name defined by the behaviour and
        # CANNOT be renamed with `!`. Raising on misconfiguration is the
        # framework-defined contract for many of these (LiveView's mount/3,
        # GenServer's init/1, etc.). BUG-8 from phoenix_live_dashboard.
        MapSet.member?(impl_set, {name, arity}) or
        # Skip protocol callback implementations: functions inside
        # `defimpl Protocol, for: Type` have names FIXED by the protocol —
        # `def write/3, do: raise("not implemented")` is the canonical
        # signal for partial implementations and can't be renamed `write!`.
        # BUG-9 from Livebook.
        MapSet.member?(defimpl_set, {name, arity}) or
        # Dunder names (`__options__`, `__using__`, `__before_compile__`)
        # are framework/macro convention — fixed names, raising-on-misconfig
        # is idiomatic.
        dunder_name?(name)
    end)
    |> Enum.filter(fn {_name, _arity, _meta, _args, body} ->
      body != nil and contains_raise?(body) and not has_rescue?(body)
    end)
    |> Enum.map(fn {name, arity, meta, _args, _body} ->
      build_diagnostic(file, name, arity, meta)
    end)
  end

  # Walk the module body in declaration order, tracking the `@impl ...` →
  # `def` adjacency. `@spec` / `@doc` and other `@` attributes between `@impl`
  # and the def preserve the flag. Returns a MapSet of {name, arity} pairs
  # for every def annotated with `@impl ...`.
  defp impl_marked_functions(ast) do
    ast
    |> all_module_bodies([])
    |> Enum.reduce(MapSet.new(), fn body, acc ->
      MapSet.union(acc, scan_impl_marks(body_statements(body), false, MapSet.new()))
    end)
  end

  # Find every `defmodule ... do ... end` body in the file, including
  # multiple top-level modules and nested ones. Handles both bare keyword
  # `[do: body]` (Code.string_to_quoted without encoder) and the
  # literal_encoder-wrapped form `[{{:__block__, _, [:do]}, body}]`
  # (production parse_file).
  defp all_module_bodies({:defmodule, _, [_alias, kw]} = node, acc) when is_list(kw) do
    case do_body(kw) do
      nil -> recurse_children(node, acc)
      body -> all_module_bodies(body, [body | acc])
    end
  end

  defp all_module_bodies({_form, _meta, args}, acc) when is_list(args) do
    Enum.reduce(args, acc, &all_module_bodies/2)
  end

  defp all_module_bodies(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &all_module_bodies/2)
  end

  defp all_module_bodies({a, b}, acc) do
    acc |> then(&all_module_bodies(a, &1)) |> then(&all_module_bodies(b, &1))
  end

  defp all_module_bodies(_, acc), do: acc

  defp recurse_children({_form, _meta, args}, acc) when is_list(args) do
    Enum.reduce(args, acc, &all_module_bodies/2)
  end

  defp recurse_children(_, acc), do: acc

  # Pluck the body from a defmodule's `do:` keyword in either form.
  defp do_body(kw) do
    Enum.find_value(kw, fn
      {:do, body} -> body
      {{:__block__, _, [:do]}, body} -> body
      _ -> nil
    end)
  end

  defp body_statements({:__block__, _, statements}), do: statements
  defp body_statements(single), do: [single]

  defp scan_impl_marks([], _flag, acc), do: acc

  # `@impl true` or `@impl SomeBehaviour` sets the flag for the next def.
  defp scan_impl_marks([{:@, _, [{:impl, _, [_value]}]} | rest], _flag, acc) do
    scan_impl_marks(rest, true, acc)
  end

  # Other module attributes (`@spec`, `@doc`, etc.) preserve the flag.
  defp scan_impl_marks([{:@, _, _} | rest], flag, acc) do
    scan_impl_marks(rest, flag, acc)
  end

  # def/defp under the impl flag — record and clear.
  defp scan_impl_marks(
         [{kind, _, [{:when, _, [{name, _, args} | _]}, _body]} | rest],
         true,
         acc
       )
       when kind in [:def, :defp] and is_atom(name) and is_list(args) do
    scan_impl_marks(rest, false, MapSet.put(acc, {name, length(args)}))
  end

  defp scan_impl_marks([{kind, _, [{name, _, args}, _body]} | rest], true, acc)
       when kind in [:def, :defp] and is_atom(name) and is_list(args) do
    scan_impl_marks(rest, false, MapSet.put(acc, {name, length(args)}))
  end

  # Any other statement clears the flag.
  defp scan_impl_marks([_ | rest], _flag, acc) do
    scan_impl_marks(rest, false, acc)
  end

  defp bang_function?(name) do
    name
    |> Atom.to_string()
    |> String.ends_with?("!")
  end

  defp dunder_name?(name) do
    name_str = Atom.to_string(name)
    String.starts_with?(name_str, "__") and String.ends_with?(name_str, "__")
  end

  # Collect {name, arity} for every `def` defined inside a `defimpl` block.
  # The protocol fixes both name and arity, so renaming with `!` would break
  # the impl contract. BUG-9 from Livebook.
  defp defimpl_callbacks(ast) do
    {_, set} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:defimpl, _, args} = node, acc when is_list(args) ->
          {node, MapSet.union(acc, defs_in_defimpl(args))}

        node, acc ->
          {node, acc}
      end)

    set
  end

  # `defimpl Protocol, for: Type, do: body` or `defimpl Protocol, for: Type do ... end`.
  # We just need the body; the structure is `[..., kw]` where `kw` is a
  # keyword list containing `:do`. Both bare and literal_encoder-wrapped forms.
  defp defs_in_defimpl(args) do
    args
    |> Enum.find_value(fn
      kw when is_list(kw) -> do_body_for_defimpl(kw)
      _ -> nil
    end)
    |> case do
      nil -> MapSet.new()
      body -> collect_def_arities(body, MapSet.new())
    end
  end

  defp do_body_for_defimpl(kw) do
    Enum.find_value(kw, fn
      {:do, body} -> body
      {{:__block__, _, [:do]}, body} -> body
      _ -> nil
    end)
  end

  defp collect_def_arities({:def, _, [{:when, _, [{name, _, args} | _]}, _]}, acc)
       when is_atom(name) and is_list(args) do
    MapSet.put(acc, {name, length(args)})
  end

  defp collect_def_arities({:def, _, [{name, _, args}, _]}, acc)
       when is_atom(name) and is_list(args) do
    MapSet.put(acc, {name, length(args)})
  end

  defp collect_def_arities({_form, _meta, args}, acc) when is_list(args) do
    Enum.reduce(args, acc, &collect_def_arities/2)
  end

  defp collect_def_arities(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_def_arities/2)
  end

  defp collect_def_arities({a, b}, acc) do
    acc |> then(&collect_def_arities(a, &1)) |> then(&collect_def_arities(b, &1))
  end

  defp collect_def_arities(_, acc), do: acc

  defp contains_raise?(body) do
    AST.contains?(body, fn
      {:raise, _, _} -> true
      _ -> false
    end)
  end

  # If the function has its own rescue block, the raise is intentionally caught
  defp has_rescue?(body) do
    AST.contains?(body, fn
      {:rescue, _} -> true
      _ -> false
    end)
  end

  defp build_diagnostic(file, name, arity, meta) do
    Diagnostic.warning("6.10",
      title: "Non-bang function raises instead of returning error tuple",
      message: "#{name}/#{arity} calls `raise` but is not named with a trailing `!`",
      why:
        "Elixir convention: functions named without `!` should return `{:ok, result}` or " <>
          "`{:error, reason}`. Functions named with `!` (like `File.read!`) may raise. When a " <>
          "non-bang function raises, callers who expect ok/error tuples get an unexpected exception " <>
          "instead. This breaks `with` chains, pattern-matched pipelines, and the caller's ability " <>
          "to decide how to handle the error. The Elixir official anti-patterns guide lists this as " <>
          "'Raising exceptions for control flow.'",
      alternatives: [
        Fix.new(
          summary: "Return `{:ok, result}` / `{:error, reason}` instead of raising",
          detail:
            "Replace `raise \"message\"` with `{:error, :descriptive_atom}` or `{:error, message}`. " <>
              "If callers need both variants, keep the raising version as `#{name}!/#{arity}` " <>
              "and make the current function return tuples.",
          example: """
          ```elixir
          # Non-bang returns tuples:
          def parse(input) do
            case do_parse(input) do
              nil -> {:error, :invalid_format}
              result -> {:ok, result}
            end
          end

          # Bang raises (for callers who want it):
          def parse!(input) do
            case parse(input) do
              {:ok, result} -> result
              {:error, reason} -> raise ArgumentError, "parse failed: \#{reason}"
            end
          end
          ```
          """,
          applies_when: "The function is called by other modules that need to handle errors."
        ),
        Fix.new(
          summary: "Rename to `#{name}!` if raising is the intended behaviour",
          detail:
            "If the raise is intentional (the function is meant to crash on invalid input, like " <>
              "a validation guard), rename it with a `!` suffix so callers know what to expect.",
          applies_when:
            "The function is intentionally strict — callers should never pass invalid input."
        ),
        Fix.new(
          summary: "Keep the raise if this is compile-time or startup validation",
          detail:
            "Raises in module body, `@` attribute evaluation, or `init/1` for missing config are " <>
              "idiomatic — they fail fast at boot, not at runtime. If the raise only fires during " <>
              "compilation or application start, it's fine.",
          applies_when: "The raise is a compile-time or startup guard, not a runtime error path."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.10"],
      context: %{function: "#{name}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
