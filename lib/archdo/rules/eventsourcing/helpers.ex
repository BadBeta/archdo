defmodule Archdo.Rules.EventSourcing.Helpers do
  @moduledoc false

  alias Archdo.AST

  @doc """
  Check if a module defines both execute/2 and apply/2 — the aggregate shape.
  """
  def aggregate_shape?(ast) do
    fns = AST.extract_functions(ast, :public)
    has_execute = Enum.any?(fns, fn {n, a, _, _, _} -> n == :execute and a == 2 end)
    has_apply = Enum.any?(fns, fn {n, a, _, _, _} -> n == :apply and a == 2 end)
    has_execute and has_apply
  end

  @doc """
  Check if a module name contains "upcast" (case-insensitive).
  """
  def upcaster_module?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, _acc ->
          is_upcaster =
            aliases
            |> Enum.map(&Atom.to_string/1)
            |> Enum.any?(fn p -> String.contains?(String.downcase(p), "upcast") end)

          {node, is_upcaster}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  @doc """
  Check if a module uses the Commanded.Aggregates.Aggregate behaviour.
  """
  def uses_aggregate_behaviour?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Commanded, :Aggregates, :Aggregate]} | _]} -> true
      _ -> false
    end)
  end
end
