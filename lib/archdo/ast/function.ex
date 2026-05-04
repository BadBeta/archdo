defmodule Archdo.AST.Function do
  @moduledoc """
  Function-level AST extractors. Walk a parsed module AST and pull
  out function definitions, GenServer callbacks, ExUnit test blocks,
  and module names.

  Public API for rule writers; re-exported via `Archdo.AST` for
  backward compatibility with existing call sites.
  """

  alias Archdo.AST

  @doc """
  Extract the top-level module name from a file's AST as a String.
  Returns "Unknown" if no defmodule is found.

  For files with nested defmodules (e.g. a private struct module
  declared inside the file's primary module), returns the OUTER
  module name. Without the "first wins" guard, prewalk visits the
  outer module first then overwrites with the inner one, returning
  the deepest nested name — wrong for callers that want the file's
  primary module.
  """
  @spec extract_module_name(Macro.t()) :: String.t()
  def extract_module_name(ast) do
    {_, name} =
      Macro.prewalk(ast, "Unknown", fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, "Unknown" ->
          case AST.safe_concat(aliases) do
            nil -> {node, "Unknown"}
            mod -> {node, AST.module_name(mod)}
          end

        node, acc ->
          {node, acc}
      end)

    name
  end

  @doc """
  Extract function definitions from a module AST.
  Returns `[{name, arity, meta, args, body}]`.
  """
  @spec extract_functions(Macro.t(), :all | :public | :private) :: [
          {atom(), non_neg_integer(), keyword(), [Macro.t()], Macro.t()}
        ]
  def extract_functions(ast, visibility \\ :all) do
    {_, fns} = Macro.prewalk(ast, [], &collect_function(&1, &2, visibility))
    Enum.reverse(fns)
  end

  # Guarded clauses wrap the head in a `:when` tuple:
  #   {:def, _, [{:when, _, [{name, _, args}, _guard]}, body]}
  # Match those FIRST — otherwise the catch-all clauses below pick up
  # `:when` as the function name and the guard's arg list as the args.
  defp collect_function(
         {:def, meta, [{:when, _, [{name, _, args} | _]}, body]} = node,
         acc,
         visibility
       )
       when visibility in [:all, :public] do
    add_extracted_fn(node, acc, name, args, meta, body)
  end

  defp collect_function(
         {:defp, meta, [{:when, _, [{name, _, args} | _]}, body]} = node,
         acc,
         visibility
       )
       when visibility in [:all, :private] do
    add_extracted_fn(node, acc, name, args, meta, body)
  end

  defp collect_function(
         {:def, meta, [{name, _, args}, body]} = node,
         acc,
         visibility
       )
       when visibility in [:all, :public] do
    add_extracted_fn(node, acc, name, args, meta, body)
  end

  defp collect_function(
         {:defp, meta, [{name, _, args}, body]} = node,
         acc,
         visibility
       )
       when visibility in [:all, :private] do
    add_extracted_fn(node, acc, name, args, meta, body)
  end

  defp collect_function(node, acc, _visibility), do: {node, acc}

  defp add_extracted_fn(node, acc, name, args, meta, body) do
    arity = length(args || [])
    {node, [{name, arity, meta, args || [], body} | acc]}
  end

  @doc """
  Extract specific GenServer callback definitions from the AST.
  Returns a map of callback_name => [{meta, args, body}].
  """
  @spec extract_callbacks(Macro.t()) ::
          %{atom() => [{keyword(), [Macro.t()], Macro.t() | nil}]}
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
  Extract the user-facing test name from the args list of an ExUnit
  `test "name", do: ...` AST. Returns the literal string when the name
  is a bare binary or wrapped by the literal-encoder, `"(unknown)"`
  otherwise (e.g. interpolated names).
  """
  @spec extract_test_name([Macro.t()]) :: String.t()
  def extract_test_name([name | _]) when is_binary(name), do: name
  def extract_test_name([{:__block__, _, [name]} | _]) when is_binary(name), do: name
  def extract_test_name(_), do: "(unknown)"

  @doc """
  Walk an ExUnit module AST and return one tuple per `test` block:
  `{name_ast, meta, body_or_nil}`. Used by testing rules that want to
  inspect each test's body (no_assertion, missing_error_path, long_test,
  over_mocking).
  """
  @spec extract_test_blocks(Macro.t()) ::
          [{Macro.t(), keyword(), Macro.t() | nil}]
  def extract_test_blocks(ast) do
    ast
    |> AST.find_all(fn
      {:test, _meta, [_name | _]} -> true
      _ -> false
    end)
    |> Enum.map(fn {:test, meta, [name | rest]} ->
      body =
        case rest do
          [_, [do: body]] -> body
          [[do: body]] -> body
          _ -> nil
        end

      {name, meta, body}
    end)
  end
end
