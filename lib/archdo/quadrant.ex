defmodule Archdo.Quadrant do
  @moduledoc false

  # §§ elixir-planning: §6 — 2-axis policy primitive for rules whose
  # finding semantics depend on the cross-product of a structural property
  # (e.g. abstraction density) and an intent classification (e.g. module
  # volatility). A rule implements `axes/3` (returns a list of
  # `{cell, evidence}` per analyzed unit), `policy/0` (maps cells to
  # `:fire` / `:no_finding` actions), and `finding_for/4` (builds a
  # Diagnostic for the actionable cell). The rule's own
  # `Archdo.Rule.analyze/3` typically delegates to `evaluate/4`.

  alias Archdo.Diagnostic

  @type axis_value :: atom()
  @type cell :: {axis_value(), axis_value()}
  @type evidence :: map()

  @type fire_action ::
          {:fire, severity :: Diagnostic.severity(), rule_id :: String.t(),
           title :: String.t()}
  @type action :: :no_finding | fire_action()

  @callback axes(file :: String.t(), ast :: Macro.t(), opts :: keyword()) ::
              [{cell(), evidence()}]

  @callback policy() :: %{cell() => action()}

  @callback finding_for(cell(), fire_action(), evidence(), file :: String.t()) ::
              Diagnostic.t()

  @doc """
  Run the quadrant pipeline for `rule` against `file`/`ast`/`opts`:

    1. Invoke `rule.axes(file, ast, opts)` to get `[{cell, evidence}, ...]`.
    2. For each cell look up `rule.policy()`. Cells absent from the policy
       are treated as `:no_finding`.
    3. For `:fire` cells, invoke `rule.finding_for(cell, action, evidence, file)`
       and collect the returned Diagnostic.

  Returns a (possibly empty) list of Diagnostics.
  """
  @spec evaluate(module(), String.t(), Macro.t(), keyword()) :: [Diagnostic.t()]
  def evaluate(rule, file, ast, opts) do
    policy = rule.policy()

    for {cell, evidence} <- rule.axes(file, ast, opts),
        action = Map.get(policy, cell, :no_finding),
        fire?(action) do
      rule.finding_for(cell, action, evidence, file)
    end
  end

  @doc """
  Cartesian product of two axis value lists. Useful for declaring an
  exhaustive `policy/0` map without hand-listing every cell.

      iex> Quadrant.cells([:high, :low], [:volatile, :stable])
      [{:high, :volatile}, {:high, :stable}, {:low, :volatile}, {:low, :stable}]
  """
  @spec cells([axis_value()], [axis_value()]) :: [cell()]
  def cells(xs, ys) when is_list(xs) and is_list(ys) do
    for x <- xs, y <- ys, do: {x, y}
  end

  @doc """
  True when `action` is a `:fire` action; false for `:no_finding` and any
  other shape. Used by `evaluate/4` and consumable by `--metrics` to
  count actionable cells.
  """
  @spec fire?(action() | term()) :: boolean()
  def fire?({:fire, _severity, _rule_id, _title}), do: true
  def fire?(_), do: false

  @doc """
  Aggregate cell occurrences from a list of `{cell, evidence}` tuples
  into a `%{cell => count}` map. The optional `policy` argument is
  carried for callers that want to combine the count with the
  policy's classification — currently unused by the implementation
  but reserved so the signature is stable across `--metrics`
  reporting changes.
  """
  @spec axes_summary([{cell(), evidence()}], %{cell() => action()}) ::
          %{cell() => non_neg_integer()}
  def axes_summary(cells, _policy) do
    Enum.reduce(cells, %{}, fn {cell, _evidence}, acc ->
      Map.update(acc, cell, 1, &(&1 + 1))
    end)
  end

  @doc """
  Filter a list of rule modules to those implementing the
  `Archdo.Quadrant` behaviour. Used by `--metrics` to discover which
  registered rules contribute to the quadrant distribution table.
  """
  @spec list_rules([module()]) :: [module()]
  def list_rules(rules) when is_list(rules) do
    Enum.filter(rules, fn module ->
      Code.ensure_loaded?(module) and
        function_exported?(module, :axes, 3) and
        function_exported?(module, :policy, 0) and
        function_exported?(module, :finding_for, 4)
    end)
  end

  @doc """
  Run `rule.axes/3` for `file`/`ast`/`opts` and return a `%{cell => count}`
  distribution. Doesn't invoke `finding_for/4` — purely a measurement
  pass for `--metrics` reporting.
  """
  @spec distribution_for(module(), String.t(), Macro.t(), keyword()) ::
          %{cell() => non_neg_integer()}
  def distribution_for(rule, file, ast, opts) do
    rule.axes(file, ast, opts)
    |> axes_summary(rule.policy())
  end
end
