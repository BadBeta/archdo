defmodule Archdo.Rules.Module.SystemTimeForDurationTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.SystemTimeForDuration

  describe "analyze/3" do
    test "flags two System.system_time calls in same function" do
      code = ~S"""
      defmodule MyApp.Bench do
        def measure(fun) do
          t0 = System.system_time(:millisecond)
          result = fun.()
          t1 = System.system_time(:millisecond)
          {result, t1 - t0}
        end
      end
      """

      diags = assert_flagged(SystemTimeForDuration, code, file: "lib/my_app/bench.ex")
      assert hd(diags).rule_id == "6.89"
    end

    test "ignores single System.system_time call (likely wall-clock use)" do
      code = ~S"""
      defmodule MyApp.Audit do
        def log_event(name) do
          {name, System.system_time(:second)}
        end
      end
      """

      assert_clean(SystemTimeForDuration, code, file: "lib/my_app/audit.ex")
    end

    test "ignores JWT iat/exp pattern (timestamps, not duration)" do
      code = ~S"""
      defmodule MyApp.Github.Crypto do
        def generate_jwt do
          %{
            "iat" => System.system_time(:second),
            "exp" => System.system_time(:second) + 600
          }
        end
      end
      """

      assert_clean(SystemTimeForDuration, code, file: "lib/my_app/crypto.ex")
    end

    test "ignores System.monotonic_time pair (correct usage)" do
      code = ~S"""
      defmodule MyApp.Bench do
        def measure(fun) do
          t0 = System.monotonic_time(:millisecond)
          fun.()
          t1 = System.monotonic_time(:millisecond)
          t1 - t0
        end
      end
      """

      assert_clean(SystemTimeForDuration, code, file: "lib/my_app/bench.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.BenchTest do
        def time(fun) do
          t0 = System.system_time(:millisecond)
          fun.()
          t1 = System.system_time(:millisecond)
          t1 - t0
        end
      end
      """

      assert_clean(SystemTimeForDuration, code, file: "test/bench_test.exs")
    end
  end
end
