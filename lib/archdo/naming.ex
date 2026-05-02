defmodule Archdo.Naming do
  @moduledoc false

  # §§ elixir-planning: §6 — Shared canonicalization helpers for rules
  # that cluster surface forms (CE-26 ScatteredTaxonomy, CE-48
  # ErrorCategoryDrift). The stem doesn't need to produce a real
  # English word — only a consistent canonical for token comparison.

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
