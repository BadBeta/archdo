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

  describe "volatility classification wiring (M15)" do
    defmodule VolatilityProbeRule do
      @moduledoc false
      @behaviour Archdo.Rule
      @impl true
      def id, do: "VOLPROBE"
      @impl true
      def description, do: "emits the seen :volatility classification as a diagnostic"
      @impl true
      def analyze(file, _ast, opts) do
        case Keyword.get(opts, :volatility) do
          nil ->
            []

          v ->
            [
              %Archdo.Diagnostic{
                rule_id: id(),
                severity: :info,
                title: "volatility seen",
                message: inspect(v.tag),
                why: "test probe",
                file: file,
                line: 1,
                context: v
              }
            ]
        end
      end
    end

    @tag :tmp_dir
    test "Runner.analyze/2 puts a Volatility classification in opts[:volatility]",
         %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "sample.ex")

      File.write!(file, """
      defmodule Sample do
        def go(url), do: Tesla.get(url)
      end
      """)

      # `:rules` overrides the registered phase1_rules — a test seam so we
      # can drive the per-file pipeline with our probe.
      [diag] = Runner.analyze([file], rules: [VolatilityProbeRule])

      seen = diag.context
      assert is_map(seen)
      assert seen.tag == :volatile
      assert {Tesla, :get, 1} in seen.evidence.volatile_calls
    end
  end

  describe "pack filtering (M13)" do
    defmodule CorePackRule do
      @behaviour Archdo.Rule
      @impl true
      def id, do: "PACKTEST.CORE"
      @impl true
      def description, do: "core pack"
      @impl true
      def analyze(file, _ast, _opts) do
        [
          %Archdo.Diagnostic{
            rule_id: id(),
            severity: :info,
            title: "core fired",
            message: "core fired",
            why: "test",
            file: file,
            line: 1
          }
        ]
      end
      @impl true
      def pack, do: :core
    end

    defmodule ComposabilityPackRule do
      @behaviour Archdo.Rule
      @impl true
      def id, do: "PACKTEST.COMPOSABILITY"
      @impl true
      def description, do: "composability pack"
      @impl true
      def analyze(file, _ast, _opts) do
        [
          %Archdo.Diagnostic{
            rule_id: id(),
            severity: :info,
            title: "composability fired",
            message: "composability fired",
            why: "test",
            file: file,
            line: 1
          }
        ]
      end
      @impl true
      def pack, do: :ce_composability
    end

    test "default packs ([:core]) excludes :ce_composability rules" do
      rules = [CorePackRule, ComposabilityPackRule]
      kept = Runner.filter_rules_for_packs(rules, [:core])

      assert CorePackRule in kept
      refute ComposabilityPackRule in kept
    end

    test "explicit [:core, :ce_composability] includes both" do
      rules = [CorePackRule, ComposabilityPackRule]
      kept = Runner.filter_rules_for_packs(rules, [:core, :ce_composability])

      assert CorePackRule in kept
      assert ComposabilityPackRule in kept
    end

    test "[:ce_composability] (no :core) excludes core rules" do
      rules = [CorePackRule, ComposabilityPackRule]
      kept = Runner.filter_rules_for_packs(rules, [:ce_composability])

      refute CorePackRule in kept
      assert ComposabilityPackRule in kept
    end

    test "rules without @pack default to :core for filtering" do
      defmodule NoPackRule do
        @behaviour Archdo.Rule
        @impl true
        def id, do: "PACKTEST.NOPACK"
        @impl true
        def description, do: "no pack callback"
        @impl true
        def analyze(_, _, _), do: []
      end

      assert NoPackRule in Runner.filter_rules_for_packs([NoPackRule], [:core])
      refute NoPackRule in Runner.filter_rules_for_packs([NoPackRule], [:ce_compliance])
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
