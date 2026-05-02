defmodule Archdo.Naming do
  @moduledoc false

  # §§ elixir-planning: §6 — Shared canonicalization helpers for rules
  # that cluster surface forms (CE-26 ScatteredTaxonomy, CE-48
  # ErrorCategoryDrift). The stem doesn't need to produce a real
  # English word — only a consistent canonical for token comparison.

  @doc """
  True when `name` is an atom that ends in `!` (the Elixir bang
  convention: `fetch!`, `create_user!`). Defensive: returns `false`
  for non-atom inputs (function names from `def unquote(...)`
  metaprogrammatic forms surface as 3-tuples, not atoms).
  """
  @spec bang?(term()) :: boolean()
  def bang?(name) when is_atom(name) do
    name |> Atom.to_string() |> String.ends_with?("!")
  end

  def bang?(_), do: false

  @doc """
  Trivial English stemmer — collapses common verbal/plural suffixes
  so `created`, `creating`, `creates`, `create` all canonicalize to
  the same stem `creat`.

  Stems applied in order: `ies → y`, `ing → ""`, `ed → ""`, `es → ""`,
  `s → ""`, trailing `e → ""`. The trailing-e strip is what unifies
  `create` with `creat` from `created`.
  """
  @spec stem(String.t()) :: String.t()
  def stem(token) when is_binary(token) do
    token
    |> String.replace_suffix("ies", "y")
    |> String.replace_suffix("ing", "")
    |> String.replace_suffix("ed", "")
    |> String.replace_suffix("es", "")
    |> String.replace_suffix("s", "")
    |> String.replace_suffix("e", "")
  end
end
