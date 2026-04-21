defmodule Archdo.Rules.Testing.AssertOnImplementationTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.AssertOnImplementation

  describe "analyze/3" do
    test "flags :sys.get_state in test file" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "updates internal counter" do
          {:ok, pid} = MyApp.Worker.start_link([])
          MyApp.Worker.increment(pid)
          state = :sys.get_state(pid)
          assert state.count == 1
        end
      end
      """

      diags = assert_flagged(AssertOnImplementation, code, file: "test/worker_test.exs")
      assert hd(diags).rule_id == "7.27"
      assert hd(diags).message =~ ":sys.get_state"
    end

    test "flags Agent.get with identity function in test file" do
      code = ~S"""
      defmodule MyApp.CacheTest do
        use ExUnit.Case

        test "stores value in agent" do
          {:ok, pid} = Agent.start_link(fn -> %{} end)
          Agent.update(pid, &Map.put(&1, :key, "value"))
          state = Agent.get(pid, & &1)
          assert state.key == "value"
        end
      end
      """

      diags = assert_flagged(AssertOnImplementation, code, file: "test/cache_test.exs")
      assert hd(diags).rule_id == "7.27"
      assert hd(diags).message =~ "Agent.get"
    end

    test "allows normal Agent.get with projection function" do
      code = ~S"""
      defmodule MyApp.CacheTest do
        use ExUnit.Case

        test "retrieves value from agent" do
          {:ok, pid} = Agent.start_link(fn -> %{key: "value"} end)
          value = Agent.get(pid, &Map.get(&1, :key))
          assert value == "value"
        end
      end
      """

      assert_clean(AssertOnImplementation, code, file: "test/cache_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Debug do
        def inspect_state(pid) do
          :sys.get_state(pid)
        end
      end
      """

      assert_clean(AssertOnImplementation, code, file: "lib/my_app/debug.ex")
    end
  end
end
