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

  @doc """
  Extract the top-level module name from a file's AST as a String.
  Returns "Unknown" if no defmodule is found.
  """
  @spec extract_module_name(Macro.t()) :: String.t()
  def extract_module_name(ast) do
    {_, name} =
      Macro.prewalk(ast, "Unknown", fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, _acc ->
          case safe_concat(aliases) do
            nil -> {node, "Unknown"}
            mod -> {node, module_name(mod)}
          end

        node, acc ->
          {node, acc}
      end)

    name
  end

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

  @doc """
  Extract a module's body as a list of statements. Returns `[]` for
  non-module nodes or modules with empty bodies. Single-statement
  bodies are returned as a one-element list.
  """
  @spec module_body(Macro.t()) :: [Macro.t()]
  def module_body({:defmodule, _, [_alias, kw]}) when is_list(kw) do
    case do_body(kw) do
      {:__block__, _, statements} -> statements
      nil -> []
      single -> [single]
    end
  end

  def module_body(_), do: []

  @doc """
  Unwrap a literal_encoder-wrapped atom (`{:__block__, _, [:atom]}`)
  to its bare atom form. Pass through anything else unchanged.
  """
  @spec unwrap_atom(Macro.t()) :: Macro.t()
  def unwrap_atom({:__block__, _, [a]}) when is_atom(a), do: a
  def unwrap_atom(other), do: other

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

  @doc """
  Extract function definitions from a module AST.
  Returns `[{name, arity, meta, args, body}]`.
  """
  @spec extract_functions(Macro.t(), :all | :public | :private) :: [
          {atom(), non_neg_integer(), keyword(), [Macro.t()], Macro.t()}
        ]
  def extract_functions(ast, visibility \\ :all) do
    {_, fns} =
      Macro.prewalk(ast, [], fn
        # Guarded clauses wrap the head in a `:when` tuple:
        #   {:def, _, [{:when, _, [{name, _, args}, _guard]}, body]}
        # Match those FIRST — otherwise the catch-all clauses below pick up
        # `:when` as the function name and the guard's arg list as the args.
        {:def, meta, [{:when, _, [{name, _, args} | _]}, body]} = node, acc
        when visibility in [:all, :public] ->
          arity = length(args || [])
          {node, [{name, arity, meta, args || [], body} | acc]}

        {:defp, meta, [{:when, _, [{name, _, args} | _]}, body]} = node, acc
        when visibility in [:all, :private] ->
          arity = length(args || [])
          {node, [{name, arity, meta, args || [], body} | acc]}

        {:def, meta, [{name, _, args}, body]} = node, acc when visibility in [:all, :public] ->
          arity = length(args || [])
          {node, [{name, arity, meta, args || [], body} | acc]}

        {:defp, meta, [{name, _, args}, body]} = node, acc when visibility in [:all, :private] ->
          arity = length(args || [])
          {node, [{name, arity, meta, args || [], body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(fns)
  end

  @doc """
  Extract specific GenServer callback definitions from the AST.
  Returns a map of callback_name => [{meta, args, body}].
  """
  @spec extract_callbacks(Macro.t()) :: %{atom() => [{keyword(), [Macro.t()], Macro.t() | nil}]}
  def extract_callbacks(ast) do
    callbacks = %{
      init: [],
      handle_call: [],
      handle_cast: [],
      handle_info: [],
      handle_continue: [],
      terminate: []
    }

    {_, result} =
      Macro.prewalk(ast, callbacks, fn
        {:def, meta, [{callback_name, _, args} | _] = clause_parts} = node, acc
        when callback_name in [
               :init,
               :handle_call,
               :handle_cast,
               :handle_info,
               :handle_continue,
               :terminate
             ] ->
          body = find_body(clause_parts)
          entry = {meta, args || [], body}
          {node, Map.update!(acc, callback_name, &[entry | &1])}

        node, acc ->
          {node, acc}
      end)

    Map.new(result, fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  defp find_body([_, [do: body]]), do: body
  defp find_body([_, body]) when is_list(body), do: Keyword.get(body, :do)
  defp find_body(_), do: nil

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

  @doc """
  Convert a module atom or Elixir.-prefixed string to a clean module name string.
  """
  @spec module_name(atom() | String.t()) :: String.t()
  def module_name(mod) when is_atom(mod) do
    mod
    |> Atom.to_string()
    |> String.replace_leading("Elixir.", "")
  end

  def module_name(mod) when is_binary(mod) do
    String.replace_leading(mod, "Elixir.", "")
  end

  @doc """
  Return the last segment of a module name (e.g. `MyApp.Accounts.User` → `"User"`).
  """
  @spec short_name(atom()) :: String.t()
  def short_name(mod) when is_atom(mod), do: List.last(Module.split(mod))

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
    _ -> nil
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

  defp body_statements({:__block__, _, statements}), do: statements
  defp body_statements(single), do: [single]

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
