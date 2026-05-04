defmodule Archdo.AST.Predicate do
  @moduledoc """
  Catch-all pattern predicates used by rules that classify argument
  shapes and terminator clauses.

  Three related but DISTINCT shapes:

    - `catch_all_arg?/1` — argument-position view: `_` and ANY bare
      variable (including `_foo`-prefixed) count as catch-all.
    - `catch_all_pattern?/1` — clause-pattern view: `_` and ordinary
      variables count, but `_foo`-prefixed names are EXCLUDED (they
      signal "intentionally unused", not a wildcard the caller forgot
      to constrain).
    - `catch_all_terminator?/1` — multi-arg view: every argument in
      a `{name, arity, meta, args, body}` clause is `catch_all_arg?`.

  Public API for rule writers; re-exported via `Archdo.AST` for
  backward compatibility with existing call sites.
  """

  @doc """
  Is the AST argument node a catch-all? Matches the wildcard `_` and any
  bare variable (`{name, _, ctx}` where both `name` and `ctx` are atoms).
  Used by rules that classify argument shapes.
  """
  @spec catch_all_arg?(Macro.t()) :: boolean()
  def catch_all_arg?({:_, _, ctx}) when is_atom(ctx), do: true
  def catch_all_arg?({var, _, ctx}) when is_atom(var) and is_atom(ctx), do: true
  def catch_all_arg?(_), do: false

  @doc """
  True if the pattern is a catch-all that shadows everything after it —
  either the bare underscore `_` or a regular variable name (which binds
  anything). Variables whose name starts with `_` are EXCLUDED — they're
  the idiomatic "intentionally unused" convention, not a wildcard the
  caller forgot to constrain.
  """
  @spec catch_all_pattern?(Macro.t()) :: boolean()
  def catch_all_pattern?({:_, _, _}), do: true

  def catch_all_pattern?({name, _, context})
      when is_atom(name) and is_atom(context) and name != :_ do
    not String.starts_with?(Atom.to_string(name), "_")
  end

  def catch_all_pattern?(_), do: false

  @doc """
  Predicate: is this clause a "catch-all terminator"?

  Takes a clause tuple from `Archdo.AST.extract_functions/2`
  (`{name, arity, meta, args, body}`). Returns true when every arg is
  a wildcard or bare variable (no nested patterns) — the canonical
  Elixir tree-walker base case (`def f(_), do: 1`,
  `def collect(_, acc), do: acc`).
  """
  @spec catch_all_terminator?(term()) :: boolean()
  def catch_all_terminator?({_name, _arity, _meta, args, _body}) when is_list(args) do
    Enum.all?(args, &catch_all_arg?/1)
  end

  def catch_all_terminator?(_), do: false
end
