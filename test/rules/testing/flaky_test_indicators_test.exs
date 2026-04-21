defmodule Archdo.Rules.Testing.FlakyTestIndicatorsTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.FlakyTestIndicators

  describe "analyze/3" do
    test "flags assert_receive without timeout" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "receives message" do
          send(self(), {:hello, "world"})
          assert_receive {:hello, _}
        end
      end
      """

      diags = assert_flagged(FlakyTestIndicators, code, file: "test/worker_test.exs")
      assert Enum.any?(diags, &(&1.message =~ "assert_receive"))
    end

    test "allows assert_receive with explicit timeout" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "receives message" do
          send(self(), {:hello, "world"})
          assert_receive {:hello, _}, 1_000
        end
      end
      """

      diags = analyze(FlakyTestIndicators, code, file: "test/worker_test.exs")
      refute Enum.any?(diags, &(&1.message =~ "assert_receive"))
    end

    test "flags :rand.uniform in test" do
      code = ~S"""
      defmodule MyApp.GameTest do
        use ExUnit.Case

        test "random roll" do
          roll = :rand.uniform(6)
          assert roll >= 1 and roll <= 6
        end
      end
      """

      diags = assert_flagged(FlakyTestIndicators, code, file: "test/game_test.exs")
      assert Enum.any?(diags, &(&1.message =~ ":rand.uniform"))
    end

    test "flags Enum.random in test" do
      code = ~S"""
      defmodule MyApp.SelectorTest do
        use ExUnit.Case

        test "picks random item" do
          item = Enum.random([:a, :b, :c])
          assert item in [:a, :b, :c]
        end
      end
      """

      diags = assert_flagged(FlakyTestIndicators, code, file: "test/selector_test.exs")
      assert Enum.any?(diags, &(&1.message =~ "Enum.random"))
    end

    test "flags DateTime.utc_now in test" do
      code = ~S"""
      defmodule MyApp.TimerTest do
        use ExUnit.Case

        test "timestamps match" do
          before = DateTime.utc_now()
          result = MyApp.Timer.record()
          assert result.timestamp == before
        end
      end
      """

      diags = assert_flagged(FlakyTestIndicators, code, file: "test/timer_test.exs")
      assert Enum.any?(diags, &(&1.message =~ "DateTime.utc_now"))
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Timer do
        def now, do: DateTime.utc_now()
        def random_id, do: :rand.uniform(1_000_000)
      end
      """

      assert_clean(FlakyTestIndicators, code, file: "lib/my_app/timer.ex")
    end
  end
end
