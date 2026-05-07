defmodule Mix.Tasks.ArchdoTest do
  use ExUnit.Case, async: true

  # The dispatch decision in Mix.Tasks.Archdo.run/1 is a pure function
  # of the parsed opts. We expose pick_command/1 as @doc false so we
  # can test the precedence rules without invoking each command.

  alias Mix.Tasks.Archdo

  describe "pick_command/1 — info commands take precedence in declared order" do
    test "explain wins when --explain is set" do
      assert {:explain, "6.4"} = Archdo.pick_command(explain: "6.4")
    end

    test "init wins over later commands" do
      assert :init = Archdo.pick_command(init: true, stats: true)
    end

    test "diagram wins over later commands" do
      assert {:diagram, "overview"} =
               Archdo.pick_command(diagram: "overview", stats: true)
    end

    test "stats wins over list_packs" do
      assert :stats = Archdo.pick_command(stats: true, list_packs: true)
    end

    test "list_packs wins over coverage" do
      assert :list_packs = Archdo.pick_command(list_packs: true, coverage: true)
    end

    test "coverage wins over pass_coverage" do
      assert :coverage = Archdo.pick_command(coverage: true, pass_coverage: true)
    end

    test "pass_coverage wins over metrics" do
      assert :pass_coverage = Archdo.pick_command(pass_coverage: true, metrics: true)
    end

    test "metrics wins over building_blocks" do
      assert :metrics = Archdo.pick_command(metrics: true, building_blocks: true)
    end

    test "building_blocks wins over compare_with" do
      assert :building_blocks =
               Archdo.pick_command(building_blocks: true, compare_with: "main")
    end
  end

  describe "pick_command/1 — action commands" do
    test "compare_with picked when set" do
      assert :compare = Archdo.pick_command(compare_with: "main")
    end

    test "freeze picked when set" do
      assert :freeze = Archdo.pick_command(freeze: true)
    end

    test "freeze_stats picked when set" do
      assert :freeze_stats = Archdo.pick_command(freeze_stats: true)
    end

    test "since picked when set" do
      assert :since = Archdo.pick_command(since: "main")
    end

    test "watch picked when set" do
      assert :watch = Archdo.pick_command(watch: true)
    end

    test "compare_with wins over freeze in declared order" do
      assert :compare = Archdo.pick_command(compare_with: "main", freeze: true)
    end
  end

  describe "pick_command/1 — default" do
    test "empty opts → :normal" do
      assert :normal = Archdo.pick_command([])
    end

    test "non-command opts → :normal" do
      assert :normal = Archdo.pick_command(paths: "lib", format: "compact")
    end
  end

  describe "pick_command/1 — false-valued boolean opts do not trigger" do
    test "init: false does not pick :init" do
      assert :normal = Archdo.pick_command(init: false)
    end

    test "stats: false does not pick :stats" do
      assert :normal = Archdo.pick_command(stats: false)
    end
  end
end
