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
    sources = transitions |> Map.keys() |> MapSet.new()

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
end
