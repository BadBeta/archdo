defmodule Archdo.AST do
  @moduledoc false

  @doc """
  Check if a path is a test file (under test/ or containing /test/).
  """
  def test_file?(file) do
    String.contains?(file, "/test/") or String.starts_with?(file, "test/")
  end

  @doc """
  Extract the top-level module name from a file's AST as a String.
  Returns "Unknown" if no defmodule is found.
  """
  def extract_module_name(ast) do
    {_, name} =
      Macro.prewalk(ast, "Unknown", fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, _acc ->
          {node, Module.concat(aliases) |> Atom.to_string() |> String.replace_leading("Elixir.", "")}

        node, acc ->
          {node, acc}
      end)

    name
  end

  @doc """
  Parse a file into its quoted AST. Returns `{:ok, ast}` or `{:error, reason}`.
  """
  def parse_file(file) do
    file
    |> File.read!()
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
  end

  @doc """
  Check if a module AST uses GenServer (has `use GenServer`).
  """
  def uses_genserver?(ast) do
    uses_module?(ast, GenServer)
  end

  @doc """
  Check if a module AST uses Agent.
  """
  def uses_agent?(ast) do
    uses_module?(ast, Agent)
  end

  @doc """
  Check if a module AST uses a given module via `use`.
  """
  def uses_module?(ast, target) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, aliases} | _]} = node, _acc ->
          module = Module.concat(aliases)

          if module == target do
            {node, true}
          else
            {node, false}
          end

        node, acc ->
          {node, acc}
      end)

    found?
  end

  @doc """
  Check if a module defines a GenServer by checking for `use GenServer`,
  `use GenStateMachine`, or defines handle_call/handle_cast/handle_info callbacks.
  """
  def genserver_module?(ast) do
    uses_genserver?(ast) || defines_genserver_callbacks?(ast)
  end

  @doc """
  Extract the line number from an AST node's metadata.
  """
  def line(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  def line(_), do: 0

  @doc """
  Walk the AST and collect all nodes matching a predicate.
  Returns a list of `{node, meta}` tuples.
  """
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

  defp defines_genserver_callbacks?(ast) do
    callbacks = extract_callbacks(ast)

    Enum.any?([:handle_call, :handle_cast, :handle_info], fn cb ->
      callbacks[cb] != []
    end)
  end
end
