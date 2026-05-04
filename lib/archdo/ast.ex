defmodule Archdo.AST do
  @moduledoc """
  Project-wide AST helpers. Every rule that walks Elixir source
  consults this module for parsing, file classification (test vs
  production, controller vs LiveView), module-name extraction,
  function enumeration, and the `@moduledoc false` predicate.

  Stable infrastructure: signature changes here ripple through every
  per-file rule. See `elixir-implementing` §10.1 for the decision
  behind keeping AST helpers at the top level rather than under
  any single context.
  """

  # File parsing IS the responsibility — every analysis path in Archdo
  # depends on `parse_file/1`. Substitutability seam doesn't apply.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  # `{:error, _}` returns are the AST helper's contract — callers (rules)
  # decide what to do with parse failures, missing atoms, etc. Logging
  # at this layer would be noise on every test/generated file skipped.
  Module.register_attribute(__MODULE__, :archdo_silent_error, persist: true)
  @archdo_silent_error true

  @doc """
  Check if a path is a test file (under test/ or containing /test/).
  """
  @spec test_file?(String.t()) :: boolean()
  def test_file?(file) do
    String.contains?(file, "/test/") or String.starts_with?(file, "test/")
  end

  @doc """
  Check if a file path belongs to a LiveView module by naming convention.
  """
  @spec live_view_file?(String.t()) :: boolean()
  def live_view_file?(file) do
    String.contains?(file, "_live.ex") or
      String.contains?(file, "/live/")
  end

  @doc """
  Check if a file path belongs to a Phoenix controller by naming convention.
  """
  @spec controller_file?(String.t()) :: boolean()
  def controller_file?(file) do
    String.contains?(file, "_controller.ex") or
      String.contains?(file, "/controllers/")
  end

  @doc """
  Check if a file path is a `mix.exs` file (project root or umbrella child).
  """
  @spec mix_exs?(String.t()) :: boolean()
  def mix_exs?(file), do: String.ends_with?(file, "mix.exs")

  @doc """
  Check if a file path contains any of the given marker substrings. Used by
  rules that classify a file as "boundary", "view", "web", "controller-or-
  channel-or-…", etc. — each carrying its own `@<role>_markers` list.
  """
  @spec path_contains_any?(String.t(), [String.t()]) :: boolean()
  def path_contains_any?(file, markers) when is_binary(file) and is_list(markers) do
    Enum.any?(markers, &String.contains?(file, &1))
  end

  @doc "See `Archdo.AST.Function.extract_module_name/1`."
  defdelegate extract_module_name(ast), to: Archdo.AST.Function

  @doc """
  Parse a list of files into `{file, ast}` tuples. Files that fail to parse
  are dropped silently (consumers that need errors should use `parse_file/1`
  per file). Project-rules consume the result; failures upstream are
  reported as their own diagnostic class.
  """
  @spec parse_files([String.t()]) :: [{String.t(), Macro.t()}]
  def parse_files(files) when is_list(files) do
    for file <- files, {:ok, ast} <- [parse_file(file)], do: {file, ast}
  end

  @doc """
  Build a `%{module_name => file}` index from a list of `{file, ast}` tuples.
  Pure; same shape used by every project-rule that needs reverse lookup.
  """
  @spec module_file_map([{String.t(), Macro.t()}]) :: %{String.t() => String.t()}
  def module_file_map(file_asts) when is_list(file_asts) do
    Map.new(file_asts, fn {file, ast} -> {extract_module_name(ast), file} end)
  end

  @doc """
  Join an alias parts list (`[:Foo, :Bar, :Baz]`) into a dotted module
  name string (`"Foo.Bar.Baz"`). Pure helper used wherever a rule walks
  `{:__aliases__, _, parts}` AST nodes.
  """
  @spec join_alias_parts([atom()]) :: String.t()
  def join_alias_parts(parts) when is_list(parts) do
    Enum.map_join(parts, ".", &Atom.to_string/1)
  end

  @doc "See `Archdo.AST.Predicate.catch_all_arg?/1`."
  defdelegate catch_all_arg?(node), to: Archdo.AST.Predicate

  @doc """
  Walk an AST collecting diagnostics. The `collector` is invoked
  per-node with `(node, acc, file)` and returns `{node, acc}`.
  Reverses the accumulated list before returning so callers see
  diagnostics in source order.

  Multiple rules share the same shape:
  `Macro.prewalk(ast, [], fn n, acc -> collect(n, acc, file) end)`
  followed by `Enum.reverse`. Centralising the dispatch here
  eliminates that boilerplate; the rule's actual logic stays
  in its `collect/3` clauses.
  """
  @spec prewalk_collect(
          String.t(),
          Macro.t(),
          (Macro.t(), [acc], String.t() -> {Macro.t(), [acc]})
        ) :: [acc]
        when acc: term()
  def prewalk_collect(file, ast, collector) when is_function(collector, 3) do
    {_, hits} = Macro.prewalk(ast, [], fn node, acc -> collector.(node, acc, file) end)
    Enum.reverse(hits)
  end

  @doc """
  Predicate: do these args (a clause's argument list) include at least
  one shape-destructuring pattern (tuple, list-cons, list literal, map,
  struct)?

  Used to classify recursive functions as "shape walkers" — multi-clause
  functions that pattern-match input shapes and recurse on the parts.
  Body recursion on bounded shape grammars (AST trees, expression
  grammars) is idiomatic and bounded by input depth.
  """
  @spec destructures?([Macro.t()] | term()) :: boolean()
  def destructures?(args) when is_list(args) do
    Enum.any?(args, fn
      {a, b} when not (is_atom(a) and is_atom(b)) -> true
      {:{}, _, _} -> true
      [{:|, _, _}] -> true
      [_ | _] -> true
      [] -> true
      {:%{}, _, _} -> true
      {:%, _, _} -> true
      _ -> false
    end)
  end

  def destructures?(_), do: false

  @doc "See `Archdo.AST.Predicate.catch_all_terminator?/1`."
  defdelegate catch_all_terminator?(clause), to: Archdo.AST.Predicate

  @doc """
  Predicate: is this multi-clause function a "shape walker"?

  Takes a list of clauses (from `extract_functions/2`). Returns true
  when at least one clause destructures a shape AND at least one
  clause is a catch-all terminator. Together those signals identify
  the canonical AST-walker idiom — bounded body recursion that
  exhausts input shapes via pattern matching.

  Used by the 6.20 (NonTailRecursion) and 6.23 (UnboundedRecursion)
  rules to exempt tree walkers from firing.
  """
  @spec shape_walker?([term()]) :: boolean()
  def shape_walker?(clauses) when is_list(clauses) do
    has_destructure = Enum.any?(clauses, fn {_, _, _, args, _} -> destructures?(args) end)
    has_terminator = Enum.any?(clauses, &catch_all_terminator?/1)
    has_destructure and has_terminator
  end

  def shape_walker?(_), do: false

  @doc "See `Archdo.AST.Unwrap.string/1`."
  defdelegate unwrap_string(ast), to: Archdo.AST.Unwrap, as: :string

  @doc """
  Return the list of statements at the top of an AST body. A bare body is
  wrapped in a one-element list; a `{:__block__, _, statements}` is
  unwrapped; nil yields an empty list.
  """
  @spec body_statements(Macro.t() | nil) :: [Macro.t()]
  def body_statements(nil), do: []
  def body_statements({:__block__, _, statements}) when is_list(statements), do: statements
  def body_statements(single), do: [single]

  @doc """
  Collect the names of `@moduledoc false` modules across a list of
  `{file, ast}` tuples. Skips modules whose name resolves to `"Unknown"`
  (no `defmodule` block found). Returned as a `MapSet.t(String.t())`
  for O(1) membership checks.
  """
  @spec collect_internal_modules([{String.t(), Macro.t()}]) :: MapSet.t(String.t())
  def collect_internal_modules(file_asts) when is_list(file_asts) do
    for {_file, ast} <- file_asts,
        internal_module?(ast),
        module = extract_module_name(ast),
        module != "Unknown",
        into: MapSet.new(),
        do: module
  end

  @doc """
  True if the node represents the literal `true` — either the bare boolean
  or the `{:__block__, _, [true]}` form emitted by Elixir's literal
  encoder. Used by rules that detect always-true conditions in `case`,
  `cond`, and `with`/`else` clauses.
  """
  @spec literal_true?(Macro.t()) :: boolean()
  def literal_true?({:__block__, _, [true]}), do: true
  def literal_true?(true), do: true
  def literal_true?(_), do: false

  @doc """
  See `Archdo.AST.Predicate.catch_all_pattern?/1`.
  """
  @spec catch_all_pattern?(Macro.t()) :: boolean()
  defdelegate catch_all_pattern?(node), to: Archdo.AST.Predicate

  @doc """
  True if the node is a callback shape — an `fn` literal or an `&`
  capture. Used by rules that walk arguments of `Enum.map`-style
  callers to inspect the callback body.
  """
  @spec callback_capture?(Macro.t()) :: boolean()
  def callback_capture?({:fn, _, _}), do: true
  def callback_capture?({:&, _, _}), do: true
  def callback_capture?(_), do: false

  @doc """
  True if the AST defines a behaviour (`@callback`) or a protocol
  (`defprotocol`). Used by metrics that compute abstraction density
  and rules that exempt behaviour-defining modules from rules
  premised on concrete modules.
  """
  @spec behaviour_or_protocol?(Macro.t()) :: boolean()
  def behaviour_or_protocol?(ast) do
    contains?(ast, fn
      {:@, _, [{:callback, _, _}]} -> true
      {:defprotocol, _, _} -> true
      _ -> false
    end)
  end

  @doc """
  True if the AST contains a `:telemetry.span/3` or `:telemetry.execute/3`
  call. Matches both the bare-atom form `:telemetry.span(...)` and the
  literal-encoder-wrapped `{:__block__, _, [:telemetry]}` form.

  Used by rule CE-27 (boundary entry without telemetry) and the plugin
  coverage matrix.
  """
  @spec contains_telemetry?(Macro.t()) :: boolean()
  def contains_telemetry?(ast) do
    contains?(ast, fn
      {{:., _, [:telemetry, fun]}, _, _} when fun in [:span, :execute] -> true
      {{:., _, [{:__block__, _, [:telemetry]}, fun]}, _, _} when fun in [:span, :execute] -> true
      _ -> false
    end)
  end

  @doc """
  True if the AST contains a `raise` expression. Used by rules that
  detect non-bang functions that raise (raise_in_non_bang) and
  rules that detect exception laundering (rescue/raise patterns).
  """
  @spec contains_raise?(Macro.t()) :: boolean()
  def contains_raise?(ast) do
    contains?(ast, fn
      {:raise, _, _} -> true
      _ -> false
    end)
  end

  @doc """
  True if a Mix dependency-options keyword list contains an `:only` key.
  Matches both the bare `{:only, _}` form and the literal-encoded
  `{{:__block__, _, [:only]}, _}` form. Used by mix.exs-walking rules
  (dev_dep_in_prod, umbrella_dep_consistency).
  """
  @spec dep_only_option?(keyword()) :: boolean()
  def dep_only_option?(opts) do
    Enum.any?(opts, fn
      {{:__block__, _, [:only]}, _} -> true
      {:only, _} -> true
      _ -> false
    end)
  end

  @doc """
  True if the AST contains a `Logger.error/warning/info/debug/notice` call.
  Used by rule CE-error-path-without-log and the plugin coverage matrix.
  """
  @spec contains_logger?(Macro.t()) :: boolean()
  def contains_logger?(ast) do
    contains?(ast, fn
      {{:., _, [{:__aliases__, _, [:Logger]}, fun]}, _, _}
      when fun in [:error, :warning, :info, :debug, :notice] ->
        true

      _ ->
        false
    end)
  end

  @doc "See `Archdo.AST.Function.extract_test_name/1`."
  defdelegate extract_test_name(args), to: Archdo.AST.Function

  @doc "See `Archdo.AST.Function.extract_test_blocks/1`."
  defdelegate extract_test_blocks(ast), to: Archdo.AST.Function

  @doc """
  Parse a file into its quoted AST. Returns `{:ok, ast}` or `{:error, reason}`.
  """
  @spec parse_file(String.t()) :: {:ok, Macro.t()} | {:error, String.t()}
  def parse_file(file) do
    case File.read(file) do
      {:ok, content} ->
        content
        |> Code.string_to_quoted(
          file: file,
          columns: true,
          token_metadata: true,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}}
        )
        |> case do
          {:ok, ast} ->
            {:ok, ast}

          {:error, {location, msg, token}} ->
            {:error, "#{file}:#{location[:line]}: #{msg}#{token}"}
        end

      {:error, reason} ->
        {:error, "#{file}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Check if a module AST uses GenServer (has `use GenServer`).
  """
  @spec uses_genserver?(Macro.t()) :: boolean()
  def uses_genserver?(ast) do
    uses_module?(ast, GenServer)
  end

  @doc """
  Check if a module AST uses Agent.
  """
  @spec uses_agent?(Macro.t()) :: boolean()
  def uses_agent?(ast) do
    uses_module?(ast, Agent)
  end

  @doc """
  Check if a module AST uses a given module via `use`.
  """
  @spec uses_module?(Macro.t(), module()) :: boolean()
  def uses_module?(ast, target) do
    contains?(ast, fn
      {:use, _, [{:__aliases__, _, aliases} | _]} -> Module.concat(aliases) == target
      _ -> false
    end)
  end

  @doc """
  Check if a module defines a GenServer by checking for `use GenServer`,
  `use GenStateMachine`, or defines handle_call/handle_cast/handle_info callbacks.
  """
  @spec genserver_module?(Macro.t()) :: boolean()
  def genserver_module?(ast) do
    uses_genserver?(ast) || defines_genserver_callbacks?(ast)
  end

  @doc """
  Extract the line number from an AST node's metadata.
  """
  @spec line(keyword() | term()) :: non_neg_integer()
  def line(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  def line(_), do: 0

  @doc """
  Find the `:do` value in a `def` / `defmodule` keyword list. Handles
  both bare (`:do`) and literal_encoder-wrapped (`{:__block__, _, [:do]}`)
  key shapes used by `parse_file/1`.

  Returns the body AST or `nil`.
  """
  @spec do_body(keyword() | term()) :: Macro.t() | nil
  def do_body(kw) when is_list(kw) do
    Enum.find_value(kw, fn
      {:do, body} -> body
      {{:__block__, _, [:do]}, body} -> body
      _ -> nil
    end)
  end

  def do_body(_), do: nil

  @doc "See `Archdo.AST.Module.body/1`."
  defdelegate module_body(ast), to: Archdo.AST.Module, as: :body

  @doc "See `Archdo.AST.Unwrap.atom/1`."
  defdelegate unwrap_atom(ast), to: Archdo.AST.Unwrap, as: :atom

  @doc "See `Archdo.AST.Unwrap.try_atom/1`."
  defdelegate try_unwrap_atom(ast), to: Archdo.AST.Unwrap, as: :try_atom

  @doc """
  Is this AST node a `0` literal (raw or literal-encoder-wrapped)?
  """
  @spec zero_literal?(Macro.t()) :: boolean()
  def zero_literal?(0), do: true
  def zero_literal?({:__block__, _, [0]}), do: true
  def zero_literal?(_), do: false

  @doc """
  Is this AST node a `def` definition (with or without a `when` guard)?
  Public-only — does NOT match `defp`. Use `extract_functions/2` if you
  need to enumerate the actual functions.
  """
  @spec def_node?(Macro.t()) :: boolean()
  def def_node?({:def, _, [{name, _, args} | _]})
      when is_atom(name) and (is_list(args) or is_nil(args)),
      do: true

  def def_node?({:def, _, [{:when, _, [{name, _, args} | _]} | _]})
      when is_atom(name) and (is_list(args) or is_nil(args)),
      do: true

  def def_node?(_), do: false

  @doc """
  Extract the parameter name from a function-arg AST node as a string.
  Recognizes bare variables (`x`) and default-value forms (`x \\\\ value`).
  Returns `nil` for unrecognized shapes (e.g., destructured arguments).
  """
  @spec arg_name(Macro.t()) :: String.t() | nil
  def arg_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: Atom.to_string(name)

  def arg_name({:\\, _, [{name, _, _} | _]}) when is_atom(name), do: Atom.to_string(name)

  def arg_name(_), do: nil

  @doc """
  Extract a `def`/`defp` clause's body from the inner argument list.
  Both `[{do: body}]` (zero-arg) and `[args, {do: body}]` (with-args)
  shapes are recognized; anything else returns `nil`.
  """
  @spec function_body(Macro.t()) :: Macro.t() | nil
  def function_body([[do: body]]), do: body
  def function_body([_args, [do: body]]), do: body
  def function_body(_), do: nil

  @doc """
  Does the module AST declare `@moduledoc false`? Equivalent shorthand
  for `internal_module?/1` but with the explicit name some rules use.
  """
  @spec moduledoc_false?(Macro.t()) :: boolean()
  def moduledoc_false?(ast), do: internal_module?(ast)

  @doc "See `Archdo.AST.Unwrap.literal/1`."
  defdelegate unwrap_literal(ast), to: Archdo.AST.Unwrap, as: :literal

  @doc """
  True when the AST contains a module attribute named `marker_name`
  with any value. Use for opt-out / opt-in markers like
  `@archdo_no_telemetry`, `@archdo_silent_error`, `@retention`, etc.

  Matches the write form `@marker_name <value>`, not bare reads.
  """
  @spec has_marker?(Macro.t(), atom()) :: boolean()
  def has_marker?(ast, marker_name) when is_atom(marker_name) do
    contains?(ast, fn
      {:@, _, [{^marker_name, _, _}]} -> true
      _ -> false
    end)
  end

  @doc """
  Collect all `@spec name(args) :: ret` declarations in an AST as a
  `MapSet` of `{name, arity}` pairs.
  """
  @spec spec_keys(Macro.t()) :: MapSet.t({atom(), arity()})
  def spec_keys(ast) do
    {_, set} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, [{:spec, _, [{:"::", _, [{name, _, args}, _ret]}]}]} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, MapSet.put(acc, {name, length(args)})}

        node, acc ->
          {node, acc}
      end)

    set
  end

  @doc """
  Walk the AST and collect all nodes matching a predicate.
  Returns a list of `{node, meta}` tuples.
  """
  @spec find_all(Macro.t(), (Macro.t() -> boolean())) :: [Macro.t()]
  def find_all(ast, predicate) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        if predicate.(node) do
          {node, [node | acc]}
        else
          {node, acc}
        end
      end)

    Enum.reverse(acc)
  end

  @doc """
  Walk the AST and check if any node inside matches a predicate.
  """
  @spec contains?(Macro.t(), (Macro.t() -> boolean())) :: boolean()
  def contains?(ast, predicate) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        node, true ->
          {node, true}

        node, false ->
          {node, predicate.(node)}
      end)

    found?
  end

  @doc "See `Archdo.AST.Function.extract_functions/2`."
  defdelegate extract_functions(ast, visibility \\ :all), to: Archdo.AST.Function

  @doc "See `Archdo.AST.Function.extract_callbacks/1`."
  defdelegate extract_callbacks(ast), to: Archdo.AST.Function

  @doc """
  Count the number of AST nodes in a tree. Useful for size-based heuristics.
  """
  @spec ast_size(term()) :: non_neg_integer()
  def ast_size(nil), do: 0

  # AST node shape `{form, meta, args}` — skip the `meta` keyword list.
  # `token_metadata: true` (used by parse_file/1) makes meta huge, and
  # counting metadata as "AST size" inflates the count by 5-15× over logical
  # complexity. Discriminator: AST nodes always have a list metadata.
  def ast_size({form, meta, args})
      when (is_atom(form) or is_tuple(form)) and is_list(meta) do
    1 + ast_size(form) + ast_size(args)
  end

  # Generic 3-tuple (data values like `{1, 2, 3}`)
  def ast_size({a, b, c}), do: 1 + ast_size(a) + ast_size(b) + ast_size(c)

  def ast_size({a, b}), do: 1 + ast_size(a) + ast_size(b)

  def ast_size(list) when is_list(list) do
    list
    |> Enum.map(&ast_size/1)
    |> Enum.sum()
  end

  def ast_size(_), do: 1

  @doc """
  Check if a module AST declares `@behaviour`.
  """
  @spec implements_behaviour?(Macro.t()) :: boolean()
  def implements_behaviour?(ast) do
    contains?(ast, fn
      {:@, _, [{:behaviour, _, _}]} -> true
      _ -> false
    end)
  end

  @doc """
  Build a project-level callback map from a list of `{file, ast}` tuples.
  For each module declaring `@callback name(args) :: return`, the result
  contains an entry `module_name => MapSet.of({name, arity})`.

  Used by rules that need to identify "is this function a callback
  implementation of a project-defined behaviour?" without relying on
  `@impl true` annotations (which older codebases often omit).
  """
  @spec collect_behaviour_callbacks([{String.t(), Macro.t()}]) ::
          %{String.t() => MapSet.t({atom(), arity()})}
  def collect_behaviour_callbacks(file_asts) do
    Enum.reduce(file_asts, %{}, fn {_file, ast}, acc ->
      case extract_module_name(ast) do
        "Unknown" ->
          acc

        mod_name ->
          callbacks = scan_callback_specs(ast)

          case MapSet.size(callbacks) do
            0 -> acc
            _ -> Map.put(acc, mod_name, callbacks)
          end
      end
    end)
  end

  defp scan_callback_specs(ast) do
    {_, callbacks} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, [{:callback, _, [{:"::", _, [{name, _, args}, _ret]}]}]} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, MapSet.put(acc, {name, length(args)})}

        {:@, _, [{:callback, _, [{:"::", _, [{name, _, nil}, _ret]}]}]} = node, acc
        when is_atom(name) ->
          {node, MapSet.put(acc, {name, 0})}

        node, acc ->
          {node, acc}
      end)

    callbacks
  end

  @doc """
  Resolve a module's `@behaviour Foo` declarations to the union of Foo's
  callbacks, given a project-level callback map (built by
  `collect_behaviour_callbacks/1`).

  Returns a `MapSet.t({name, arity})` of every callback the module
  implicitly implements via its declared behaviours. Useful for rules
  that want to treat callback-impl public functions differently from
  ordinary public API.

  Behaviours unknown to the map (e.g. `GenServer` from OTP, or a
  library's behaviour that's outside the analyzed paths) contribute
  nothing — only project-defined behaviours resolve.
  """
  @spec module_implemented_callbacks(
          Macro.t(),
          %{String.t() => MapSet.t({atom(), arity()})}
        ) :: MapSet.t({atom(), arity()})
  def module_implemented_callbacks(ast, callbacks_map) when is_map(callbacks_map) do
    ast
    |> declared_behaviour_names()
    |> Enum.reduce(MapSet.new(), fn behaviour_name, acc ->
      Map.get(callbacks_map, behaviour_name, MapSet.new()) |> MapSet.union(acc)
    end)
  end

  defp declared_behaviour_names(ast) do
    {_, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]} = node, acc when is_list(parts) ->
          name = parts |> Module.concat() |> module_name()
          {node, MapSet.put(acc, name)}

        {:@, _, [{:behaviour, _, [atom]}]} = node, acc when is_atom(atom) ->
          {node, MapSet.put(acc, module_name(atom))}

        node, acc ->
          {node, acc}
      end)

    names
  end

  @doc """
  Check if the caller module shares a root namespace with target module parts,
  indicating a self-call rather than an external dependency.
  """
  @spec self_call?(String.t(), [atom()]) :: boolean()
  def self_call?(caller_module, target_parts) when is_list(target_parts) do
    caller_root =
      caller_module
      |> to_string()
      |> String.replace_leading("Elixir.", "")
      |> String.split(".")
      |> hd()

    target_root =
      target_parts
      |> hd()
      |> to_string()

    caller_root == target_root
  end

  @doc "See `Archdo.AST.Module.name/1`."
  defdelegate module_name(mod), to: Archdo.AST.Module, as: :name

  @doc """
  Return the last segment of a module name (e.g. `MyApp.Accounts.User` → `"User"`).
  Accepts an atom or a dotted string.
  """
  @spec short_name(atom() | String.t()) :: String.t()
  def short_name(mod) when is_atom(mod), do: List.last(Module.split(mod))
  def short_name(mod) when is_binary(mod), do: mod |> String.split(".") |> List.last()

  @doc """
  Check if a module-alias parts list points at an `Ecto.Repo`-shaped module.
  Matches both bare `Repo` (final segment) and any namespace ending in `Repo`.
  """
  @spec repo_module?([atom()]) :: boolean()
  def repo_module?(aliases) when is_list(aliases) do
    case List.last(aliases) do
      :Repo -> true
      _ -> Enum.any?(aliases, &(&1 == :Repo))
    end
  end

  @doc """
  The Ecto Repo alias atom. Centralized so consumers detecting Ecto
  Repo references don't each carry their own `== :Repo` literal.
  """
  @spec repo_atom() :: :Repo
  def repo_atom, do: :Repo

  @doc """
  Check if a file path starts with any of the given path roots. Used by rules
  that scope analysis to a project-configured set of directories.
  """
  @spec path_starts_with_any?(String.t(), [String.t()]) :: boolean()
  def path_starts_with_any?(file, paths) when is_binary(file) and is_list(paths) do
    Enum.any?(paths, &String.starts_with?(file, &1))
  end

  @doc "See `Archdo.AST.Module.under_namespace?/2`."
  defdelegate module_under_namespace?(name, namespace), to: Archdo.AST.Module, as: :under_namespace?

  @doc """
  Resolve a module-name string to its existing atom. Returns `nil` when no
  such atom exists in the BEAM atom table (avoids unbounded atom creation
  on untrusted input). Strips/restores the `Elixir.` prefix automatically.
  """
  @spec safe_existing_atom(String.t()) :: module() | nil
  def safe_existing_atom(name) when is_binary(name) do
    String.to_existing_atom("Elixir." <> name)
  rescue
    ArgumentError -> nil
  end

  @doc """
  Wrap `String.to_existing_atom/1` into `{:ok, atom} | :error`. Use for raw
  names (function names, etc.) where you don't want to create new atoms on
  untrusted input — and where `nil` is ambiguous because `nil` itself is a
  valid atom.
  """
  @spec try_existing_atom(String.t()) :: {:ok, atom()} | :error
  def try_existing_atom(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  @doc """
  Safely concatenate alias parts into a module atom.
  Handles `__MODULE__` and other non-atom AST nodes by converting to string.
  Returns nil if the alias list is empty or entirely dynamic.
  """
  @spec safe_concat([atom() | term()]) :: atom() | nil
  def safe_concat([]), do: nil

  def safe_concat(aliases) when is_list(aliases) do
    parts =
      Enum.map(aliases, fn
        part when is_atom(part) -> part
        {:__MODULE__, _, _} -> :__MODULE__
        {:__block__, _, [atom]} when is_atom(atom) -> atom
        _ -> nil
      end)

    case Enum.any?(parts, &is_nil/1) do
      true -> nil
      false -> Module.concat(parts)
    end
  rescue
    # `Module.concat/1` raises ArgumentError for malformed input that
    # slipped past the parts-filter above (empty list, exotic non-atoms).
    # The function's contract returns `nil` for unparseable aliases.
    ArgumentError -> nil
  end

  @doc """
  Check if a module AST is a NIF module (uses Rustler, Zig, or has @on_load).
  """
  @spec nif_module?(Macro.t()) :: boolean()
  def nif_module?(ast) do
    contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Rustler]} | _]} -> true
      {:use, _, [{:__aliases__, _, [:Zig]} | _]} -> true
      {:@, _, [{:on_load, _, _}]} -> true
      {{:., _, [:erlang, :load_nif]}, _, _} -> true
      _ -> false
    end)
  end

  @doc """
  Normalize a file path to be relative to the current working directory.
  """
  @spec relative_path(String.t()) :: String.t()
  def relative_path(path) when is_binary(path) do
    case File.cwd() do
      {:ok, cwd} -> Path.relative_to(path, cwd)
      _ -> path
    end
  end

  def relative_path(path), do: to_string(path)

  @doc """
  Check if the given AST body contains a self-call to `name/arity`.
  """
  @spec has_self_call?(Macro.t(), atom(), non_neg_integer()) :: boolean()
  def has_self_call?(body, name, arity) do
    contains?(body, fn
      {^name, _, args} when is_list(args) -> length(args) == arity
      _ -> false
    end)
  end

  @doc """
  Check if a module AST has `@moduledoc false`, indicating an internal module.
  """
  @spec internal_module?(Macro.t()) :: boolean()
  def internal_module?(ast) do
    contains?(ast, fn
      # Production parse_file/1 uses literal_encoder, which wraps `false` as
      # `{:__block__, _, [false]}`. Code.string_to_quoted/1 (no encoder, used by
      # some tests) keeps the bare form. Match both so the rule fires either way.
      {:@, _, [{:moduledoc, _, [false]}]} -> true
      {:@, _, [{:moduledoc, _, [{:__block__, _, [false]}]}]} -> true
      _ -> false
    end)
  end

  @doc """
  Walk up from `file` to find the nearest `mix.exs`. Returns the project root
  directory (the one containing `mix.exs`) or `nil` if none found before /.
  """
  @spec find_mix_root(String.t()) :: String.t() | nil
  def find_mix_root(file) when is_binary(file) do
    file
    |> Path.expand()
    |> Path.dirname()
    |> walk_up_for_mix()
  end

  defp walk_up_for_mix("/"), do: nil

  defp walk_up_for_mix(dir) do
    case File.exists?(Path.join(dir, "mix.exs")) do
      true -> dir
      false -> walk_up_for_mix(Path.dirname(dir))
    end
  end

  @doc """
  Extract the `:test_paths` list from a project's `mix.exs`. Returns
  `["test"]` (the Mix default) when not declared or when mix.exs cannot
  be parsed. Reads from disk; safe to call repeatedly.
  """
  @spec test_paths_from_mix(String.t() | nil) :: [String.t()]
  def test_paths_from_mix(nil), do: ["test"]

  def test_paths_from_mix(project_root) do
    mix_file = Path.join(project_root, "mix.exs")

    with {:ok, content} <- File.read(mix_file),
         {:ok, ast} <- Code.string_to_quoted(content) do
      extract_test_paths(ast) || ["test"]
    else
      _ -> ["test"]
    end
  end

  defp extract_test_paths(ast) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        # Match a literal list of strings keyed under :test_paths within any keyword pair.
        {:test_paths, paths} = node, _ when is_list(paths) ->
          {node, list_of_strings(paths)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp list_of_strings(list) do
    case Enum.all?(list, &is_binary/1) do
      true -> list
      false -> nil
    end
  end

  @doc """
  Detect whether a project is shaped as a publishable library: its `mix.exs`
  declares either a `package:` keyword in `project/0` or a `package/0` function.
  Returns `false` when no `mix.exs` is found or it can't be parsed.
  """
  @spec library?(String.t() | nil) :: boolean()
  def library?(nil), do: false

  def library?(project_root) do
    mix_file = Path.join(project_root, "mix.exs")

    with {:ok, content} <- File.read(mix_file),
         {:ok, ast} <- Code.string_to_quoted(content) do
      contains?(ast, fn
        {:package, _} -> true
        {:def, _, [{:package, _, _} | _]} -> true
        {:defp, _, [{:package, _, _} | _]} -> true
        _ -> false
      end)
    else
      _ -> false
    end
  end

  @doc """
  Collect every `def` annotated with `@impl ...` in the AST.

  Walks each `defmodule` body in declaration order, tracking the
  `@impl ... → def` adjacency. `@spec`/`@doc` and other attributes
  between `@impl` and the def preserve the flag. Any non-attribute,
  non-def statement clears it.

  Returns a `MapSet` of `{name, arity}` pairs. Useful for any rule
  that needs to know "is this function a behaviour callback whose
  name+arity are framework-defined?" — e.g. exempting framework
  callbacks from naming/arity/raise conventions.

  Handles both bare `[do: body]` and the literal_encoder-wrapped
  `[{{:__block__, _, [:do]}, body}]` form used by `parse_file/1`.
  """
  @spec impl_callbacks(Macro.t()) :: MapSet.t({atom(), arity()})
  def impl_callbacks(ast) do
    ast
    |> all_module_bodies([])
    |> Enum.reduce(MapSet.new(), fn body, acc ->
      MapSet.union(acc, scan_impl_marks(body_statements(body), false, MapSet.new()))
    end)
  end

  @doc """
  Collect every `def` defined inside any `defimpl Protocol, for: Type do ... end`
  block in the AST.

  Returns a `MapSet` of `{name, arity}` pairs. Functions inside `defimpl`
  have names FIXED by the protocol's `defprotocol` declaration, so rules
  about naming, arity, or raising conventions should typically exempt them.
  """
  @spec defimpl_callbacks(Macro.t()) :: MapSet.t({atom(), arity()})
  def defimpl_callbacks(ast) do
    {_, set} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:defimpl, _, args} = node, acc when is_list(args) ->
          {node, MapSet.union(acc, defs_in_defimpl(args))}

        node, acc ->
          {node, acc}
      end)

    set
  end

  # --- private helpers for the two functions above ---

  defp all_module_bodies({:defmodule, _, [_alias, kw]} = node, acc) when is_list(kw) do
    case do_body(kw) do
      nil -> recurse_module_children(node, acc)
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

  defp recurse_module_children({_form, _meta, args}, acc) when is_list(args) do
    Enum.reduce(args, acc, &all_module_bodies/2)
  end

  defp scan_impl_marks([], _flag, acc), do: acc

  defp scan_impl_marks([{:@, _, [{:impl, _, [_value]}]} | rest], _flag, acc) do
    scan_impl_marks(rest, true, acc)
  end

  # Other module attributes (`@spec`, `@doc`, etc.) preserve the flag.
  defp scan_impl_marks([{:@, _, _} | rest], flag, acc) do
    scan_impl_marks(rest, flag, acc)
  end

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

  defp scan_impl_marks([_ | rest], _flag, acc) do
    scan_impl_marks(rest, false, acc)
  end

  defp defs_in_defimpl(args) do
    args
    |> Enum.find_value(fn
      kw when is_list(kw) -> do_body(kw)
      _ -> nil
    end)
    |> case do
      nil -> MapSet.new()
      body -> collect_def_arities(body, MapSet.new())
    end
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

  defp defines_genserver_callbacks?(ast) do
    callbacks = extract_callbacks(ast)

    Enum.any?([:handle_call, :handle_cast, :handle_info], fn cb ->
      match?([_ | _], callbacks[cb])
    end)
  end
end
