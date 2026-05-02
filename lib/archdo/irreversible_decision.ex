defmodule Archdo.IrreversibleDecision do
  @moduledoc false

  # §§ elixir-planning: §6 — Group D foundation. Identifies modules
  # representing hard-to-reverse decisions: Ecto schemas (data shape
  # rolled out to a database), supervisors (process topology baked
  # into deploys), and modules under configurable public-API paths
  # (consumed by other apps). M28 CE-11 / CE-12 fire on these.

  alias Archdo.AST

  @schema_uses [Ecto.Schema, [:Ecto, :Schema]]
  @supervisor_uses [
    Supervisor,
    DynamicSupervisor,
    [:Supervisor],
    [:DynamicSupervisor]
  ]

  @doc """
  True when the module is an irreversible decision per the rule
  spec: Ecto schema, Supervisor / DynamicSupervisor module, or located
  under a configured `public_api_paths` prefix.

  `opts` accepts `:public_api_paths` — a list of path prefixes whose
  modules are public API. Defaults to `[]`.
  """
  @spec candidate?(String.t(), Macro.t(), keyword()) :: boolean()
  def candidate?(file, ast, opts \\ []) do
    paths = Keyword.get(opts, :public_api_paths, [])

    schema?(ast) or supervisor?(ast) or under_public_api_path?(file, paths)
  end

  defp schema?(ast) do
    has_use?(ast, @schema_uses)
  end

  defp supervisor?(ast) do
    has_use?(ast, @supervisor_uses) or defines_child_spec?(ast)
  end

  defp under_public_api_path?(file, paths) do
    Enum.any?(paths, &String.starts_with?(file, &1))
  end

  defp has_use?(ast, targets) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, parts}]} when is_list(parts) -> parts in targets
      {:use, _, [{:__aliases__, _, parts}, _opts]} when is_list(parts) -> parts in targets
      {:use, _, [mod]} when is_atom(mod) -> mod in targets
      _ -> false
    end)
  end

  defp defines_child_spec?(ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.any?(fn {name, arity, _, _, _} -> name == :child_spec and arity == 1 end)
  end
end
