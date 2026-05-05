defmodule Archdo.AST.Unwrap do
  @moduledoc """
  AST literal-unwrapping helpers. `Code.string_to_quoted/2` with
  `literal_encoder: &{:ok, {:__block__, &2, [&1]}}` (Archdo's parsing
  default — see `Archdo.AST.parse_file/1`) wraps every literal in a
  `{:__block__, meta, [value]}` envelope. Rules that pattern-match
  on those literals call into this module to peel the wrapper.

  Public API for rule writers; re-exported via `Archdo.AST` for
  backward compatibility with existing call sites.
  """

  @doc """
  Unwrap a string literal. Returns `nil` for non-strings — use a
  different helper if you need a fallback to `Macro.to_string/1`.
  """
  @spec string(Macro.t()) :: String.t() | nil
  def string({:__block__, _, [s]}) when is_binary(s), do: s
  def string(s) when is_binary(s), do: s
  def string(_), do: nil

  @doc """
  Unwrap a literal_encoder-wrapped atom (`{:__block__, _, [:atom]}`)
  to its bare atom form. Pass through anything else unchanged.
  """
  @spec atom(Macro.t()) :: Macro.t()
  def atom({:__block__, _, [a]}) when is_atom(a), do: a
  def atom(other), do: other

  @doc """
  Strict variant of `atom/1`: returns the atom if the input is one
  (possibly literal-encoder-wrapped), or `nil` for anything else. Use
  when downstream code filters via `Enum.reject(&is_nil/1)` and would
  silently misbehave on non-atom passthrough.
  """
  @spec try_atom(Macro.t()) :: atom() | nil
  def try_atom({:__block__, _, [a]}) when is_atom(a), do: a
  def try_atom(a) when is_atom(a), do: a
  def try_atom(_), do: nil

  @doc """
  Type-agnostic literal unwrap. Returns the inner value for any
  literal-wrapped node; returns the input unchanged for non-literals.
  Use when the unwrap target could be an atom, integer, float, string,
  or any other literal.
  """
  @spec literal(Macro.t()) :: Macro.t()
  def literal({:__block__, _, [v]}), do: v
  def literal(other), do: other

  @doc """
  Look up a key in a 2-tuple-pair keyword list, tolerating both bare
  atom keys (`Code.string_to_quoted/1`) and literal-encoder-wrapped
  keys (`{:__block__, _, [:atom]}` from `Archdo.AST.parse_files/1`).
  Returns `{:ok, val}` or `:error`.

  Common use: extract the `:do` body from a `def`/`defp`/`case`/`with`
  AST node uniformly across both AST sources.
  """
  @spec kw_get([{Macro.t(), Macro.t()}], atom()) :: {:ok, Macro.t()} | :error
  def kw_get([], _target), do: :error

  def kw_get([{key, val} | rest], target) do
    case try_atom(key) do
      ^target -> {:ok, val}
      _ -> kw_get(rest, target)
    end
  end

  def kw_get([_ | rest], target), do: kw_get(rest, target)
end
