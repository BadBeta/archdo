defmodule Archdo.CompareTest do
  use ExUnit.Case, async: true

  alias Archdo.{Compare, Diagnostic}

  defp diag(rule_id, severity, file \\ "lib/x.ex") do
    Diagnostic.builder_for(severity).(rule_id,
      title: "t",
      message: "m",
      why: "why",
      file: file,
      line: 1
    )
  end

  describe "aggregate/1" do
    test "groups diagnostics by {rule_id, severity}" do
      diagnostics = [
        diag("CE-1", :warning),
        diag("CE-1", :warning),
        diag("CE-2", :info),
        diag("CE-2", :info),
        diag("CE-2", :info)
      ]

      result = Compare.aggregate(diagnostics)

      assert result[{"CE-1", :warning}] == 2
      assert result[{"CE-2", :info}] == 3
    end

    test "returns empty map for empty diagnostics" do
      assert Compare.aggregate([]) == %{}
    end

    test "counts the same rule fired at different severities separately" do
      diagnostics = [
        diag("CE-23", :warning),
        diag("CE-23", :error),
        diag("CE-23", :error)
      ]

      result = Compare.aggregate(diagnostics)

      assert result[{"CE-23", :warning}] == 1
      assert result[{"CE-23", :error}] == 2
    end
  end

  describe "merge/1" do
    test "merges per-codebase aggregates into a side-by-side table" do
      per_codebase = [
        {"my_project", %{{"CE-1", :warning} => 5, {"CE-2", :info} => 10}},
        {"phoenix", %{{"CE-1", :warning} => 0, {"CE-2", :info} => 3}},
        {"ecto", %{{"CE-2", :info} => 7}}
      ]

      table = Compare.merge(per_codebase)

      assert {"CE-1", :warning} in Map.keys(table.rows)
      assert {"CE-2", :info} in Map.keys(table.rows)
      assert table.codebases == ["my_project", "phoenix", "ecto"]

      ce1_row = table.rows[{"CE-1", :warning}]
      assert ce1_row["my_project"] == 5
      assert ce1_row["phoenix"] == 0
      assert ce1_row["ecto"] == 0
    end

    test "all rule keys appear in every codebase row (zero-fill)" do
      per_codebase = [
        {"a", %{{"CE-1", :warning} => 3}},
        {"b", %{{"CE-99", :info} => 1}}
      ]

      table = Compare.merge(per_codebase)
      ce1 = table.rows[{"CE-1", :warning}]
      ce99 = table.rows[{"CE-99", :info}]

      assert ce1["b"] == 0
      assert ce99["a"] == 0
    end
  end

  describe "format/1" do
    test "renders a readable table with codebases as columns" do
      table = %{
        codebases: ["my_project", "phoenix"],
        rows: %{
          {"CE-1", :warning} => %{"my_project" => 5, "phoenix" => 0},
          {"CE-2", :info} => %{"my_project" => 10, "phoenix" => 3}
        }
      }

      output = Compare.format(table)

      assert is_binary(output)
      assert output =~ "CE-1"
      assert output =~ "CE-2"
      assert output =~ "my_project"
      assert output =~ "phoenix"
    end
  end
end
