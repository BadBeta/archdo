defmodule Archdo.AST do
  @moduledoc false

  @doc """
  Check if a path is a test file (under test/ or containing /test/).
  """
  @spec test_file?(String.t()) :: boolean()
  def test_file?(file) do
    String.contains?(file, "/test/") or String.starts_with?(file, "test/")
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
          {:ok, ast} -> {:ok, ast}
          {:error, {location, msg, token}} -> {:error, "#{file}:#{location[:line]}: #{msg}#{token}"}
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
        when callback_name in [:init, :handle_call, :handle_cast, :handle_info, :handle_continue, :terminate] ->
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

  defp defines_genserver_callbacks?(ast) do
    callbacks = extract_callbacks(ast)

    Enum.any?([:handle_call, :handle_cast, :handle_info], fn cb ->
      match?([_ | _], callbacks[cb])
    end)
  end
end
