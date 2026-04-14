defmodule Archdo.RunnerTest do
  use ExUnit.Case, async: true

  alias Archdo.Runner

  describe "phase1_rules/0" do
    test "returns a non-empty list of modules" do
      rules = Runner.phase1_rules()
      assert [_ | _] = rules
      assert Enum.all?(rules, &is_atom/1)
    end

    test "all rule modules implement the Archdo.Rule behaviour" do
      for rule <- Runner.phase1_rules() do
        assert function_exported?(rule, :id, 0),
               "#{inspect(rule)} missing id/0"

        assert function_exported?(rule, :description, 0),
               "#{inspect(rule)} missing description/0"

        assert function_exported?(rule, :analyze, 3),
               "#{inspect(rule)} missing analyze/3"
      end
    end

    test "all rules have unique ids" do
      ids = Enum.map(Runner.phase1_rules(), & &1.id())
      assert ids == Enum.uniq(ids), "Duplicate rule IDs found"
    end
  end

  describe "graph_rules/0" do
    test "returns a list of graph rule modules" do
      rules = Runner.graph_rules()
      assert is_list(rules)
      assert Enum.all?(rules, &is_atom/1)
    end
  end

  describe "analyze/2" do
    test "returns empty list for non-existent file" do
      diagnostics = Runner.analyze(["non_existent_file_#{:rand.uniform(100_000)}.ex"])
      assert diagnostics == []
    end

    test "returns empty list for file that fails to parse" do
      path = Path.join(System.tmp_dir!(), "archdo_bad_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "this is not valid elixir @@@ !!!")

      try do
        diagnostics = Runner.analyze([path])
        assert diagnostics == []
      after
        File.rm(path)
      end
    end

    test "returns diagnostics list for valid Elixir files" do
      # Create a temporary file with a known issue
      path = Path.join(System.tmp_dir!(), "archdo_test_#{:rand.uniform(100_000)}.ex")

      File.write!(path, """
      defmodule TestModule do
        use GenServer

        def handle_info(_msg, state) do
          {:noreply, state}
        end
      end
      """)

      try do
        diagnostics = Runner.analyze([path])
        assert is_list(diagnostics)
        # The silent catch-all rule should fire
        assert Enum.any?(diagnostics, &(&1.rule_id == "5.14"))
      after
        File.rm(path)
      end
    end

    test "respects :only filter" do
      path = Path.join(System.tmp_dir!(), "archdo_test_only_#{:rand.uniform(100_000)}.ex")

      File.write!(path, """
      defmodule TestModule do
        use GenServer

        def handle_info(_msg, state) do
          {:noreply, state}
        end
      end
      """)

      try do
        # Only run rule 5.14
        diagnostics = Runner.analyze([path], only: ["5.14"])
        assert Enum.all?(diagnostics, &(&1.rule_id == "5.14"))

        # Only run a rule that won't match
        diagnostics = Runner.analyze([path], only: ["99.99"])
        assert diagnostics == []
      after
        File.rm(path)
      end
    end

    test "respects :ignore filter" do
      path = Path.join(System.tmp_dir!(), "archdo_test_ignore_#{:rand.uniform(100_000)}.ex")

      File.write!(path, """
      defmodule TestModule do
        use GenServer

        def handle_info(_msg, state) do
          {:noreply, state}
        end
      end
      """)

      try do
        diagnostics = Runner.analyze([path], ignore: ["5.14"])
        refute Enum.any?(diagnostics, &(&1.rule_id == "5.14"))
      after
        File.rm(path)
      end
    end
  end
end
