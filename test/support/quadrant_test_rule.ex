defmodule Archdo.QuadrantTestRule do
  @moduledoc false

  # Synthetic fixture rule for exercising the Archdo.Quadrant primitive.
  # Tests inject the cells the rule should "compute" via the Process
  # dictionary key `:quadrant_test_cells` so each test drives a different
  # policy outcome without parsing real ASTs.

  @behaviour Archdo.Rule
  @behaviour Archdo.Quadrant

  alias Archdo.{Diagnostic, Quadrant}

  @impl Archdo.Rule
  def id, do: "QTEST.fire-hv"

  @impl Archdo.Rule
  def description, do: "Quadrant test fixture rule"

  @impl Archdo.Rule
  def analyze(file, ast, opts) do
    Quadrant.evaluate(__MODULE__, file, ast, opts)
  end

  @impl Archdo.Quadrant
  def axes(_file, _ast, _opts) do
    Process.get(:quadrant_test_cells, [{{:low, :stable}, %{line: 1}}])
  end

  @impl Archdo.Quadrant
  def policy do
    %{
      {:high, :volatile} => {:fire, :warning, "QTEST.fire-hv", "high-volatile actionable"},
      {:low, :volatile} => {:fire, :info, "QTEST.fire-lv", "low-volatile suggest"},
      {:high, :stable} => :no_finding,
      {:low, :stable} => :no_finding
    }
  end

  @impl Archdo.Quadrant
  def finding_for(cell, {:fire, severity, rule_id, title}, evidence, file) do
    %Diagnostic{
      rule_id: rule_id,
      severity: severity,
      title: title,
      message: "fired in cell #{inspect(cell)}",
      why: "test",
      file: file,
      line: Map.get(evidence, :line, 1)
    }
  end
end
