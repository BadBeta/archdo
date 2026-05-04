defmodule Archdo.AST.Module do
  @moduledoc """
  Module-level AST helpers — name normalization, module-body
  extraction, and namespace-membership checks. Operates on the
  `defmodule` AST shape and the dotted-string / atom representations
  of module names.

  Public API for rule writers; re-exported via `Archdo.AST` for
  backward compatibility with existing call sites.
  """

  alias Archdo.AST

  @doc """
  Convert a module atom or `Elixir.`-prefixed string to a clean
  module name string. Idempotent — strings without the prefix pass
  through unchanged.

      iex> Archdo.AST.Module.name(MyApp.Accounts)
      "MyApp.Accounts"
      iex> Archdo.AST.Module.name("Elixir.MyApp.Accounts")
      "MyApp.Accounts"
      iex> Archdo.AST.Module.name("MyApp.Accounts")
      "MyApp.Accounts"
  """
  @spec name(atom() | String.t()) :: String.t()
  def name(mod) when is_atom(mod) do
    mod
    |> Atom.to_string()
    |> String.replace_leading("Elixir.", "")
  end

  def name(mod) when is_binary(mod) do
    String.replace_leading(mod, "Elixir.", "")
  end

  @doc """
  Extract a module's body as a list of statements. Returns `[]` for
  non-module nodes or modules with empty bodies. Single-statement
  bodies are returned as a one-element list.
  """
  @spec body(Macro.t()) :: [Macro.t()]
  def body({:defmodule, _, [_alias, kw]}) when is_list(kw) do
    case AST.do_body(kw) do
      {:__block__, _, statements} -> statements
      nil -> []
      single -> [single]
    end
  end

  def body(_), do: []

  @doc """
  Check if a module name is the namespace itself or lives under it
  (i.e. `name == namespace` or starts with `namespace.`). Operates on
  string forms.

      iex> Archdo.AST.Module.under_namespace?("MyApp.Accounts.User", "MyApp.Accounts")
      true
      iex> Archdo.AST.Module.under_namespace?("MyApp.Accounts", "MyApp.Accounts")
      true
      iex> Archdo.AST.Module.under_namespace?("MyApp.Catalog", "MyApp.Accounts")
      false
  """
  @spec under_namespace?(String.t(), String.t()) :: boolean()
  def under_namespace?(name, namespace) when is_binary(name) and is_binary(namespace) do
    name == namespace or String.starts_with?(name, namespace <> ".")
  end
end
