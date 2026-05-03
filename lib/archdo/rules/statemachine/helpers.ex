defmodule Archdo.Rules.StateMachine.Helpers do
  @moduledoc false

  @doc """
  Convert AST-extracted state/target pairs into a transition map.
  Handles literal_encoder-wrapped keys.
  """
  @spec pairs_to_transition_map([{term(), term()}]) :: %{String.t() => [String.t()]}
  def pairs_to_transition_map(pairs) do
    Map.new(pairs, fn
      {{:__block__, _, [key]}, targets} -> {key, extract_string_list(targets)}
      {key, targets} -> {key, extract_string_list(targets)}
    end)
  end

  @doc """
  Collect all unique states (both source and target) from a transition map.
  """
  @spec collect_all_states(%{String.t() => [String.t()]}) :: MapSet.t(String.t())
  def collect_all_states(transitions) do
    sources =
      transitions
      |> Map.keys()
      |> MapSet.new()

    targets =
      transitions
      |> Map.values()
      |> List.flatten()
      |> MapSet.new()

    MapSet.union(sources, targets)
  end

  defp extract_string_list(list) when is_list(list) do
    Enum.map(list, fn
      {:__block__, _, [v]} when is_binary(v) -> v
      v when is_binary(v) -> v
      _ -> "?"
    end)
  end

  @doc """
  Extract the `@states [:a, :b, :c]` declaration from a module AST.
  Returns a `MapSet` of declared state atoms, or `nil` if no
  declaration is present (rules using this should treat `nil` as
  "rule does not apply — opt-in via @states").

  Handles both bare lists and the literal_encoder-wrapped form.
  """
  @spec declared_states(Macro.t()) :: MapSet.t(atom()) | nil
  def declared_states(ast) do
    nodes =
      Archdo.AST.find_all(ast, fn
        {:@, _, [{:states, _, [_]}]} -> true
        _ -> false
      end)

    Enum.find_value(nodes, fn
      {:@, _, [{:states, _, [list]}]} -> extract_atom_list(list)
      _ -> nil
    end)
  end

  defp extract_atom_list({:__block__, _, [list]}) when is_list(list), do: extract_atom_list(list)

  defp extract_atom_list(list) when is_list(list) do
    atoms =
      Enum.flat_map(list, fn
        {:__block__, _, [a]} when is_atom(a) -> [a]
        a when is_atom(a) -> [a]
        _ -> []
      end)

    case atoms do
      [] -> nil
      list -> MapSet.new(list)
    end
  end

  defp extract_atom_list(_), do: nil
end
