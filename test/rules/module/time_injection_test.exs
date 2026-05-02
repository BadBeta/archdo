defmodule Archdo.Rules.Module.TimeInjectionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.TimeInjection

  describe "analyze/3" do
    test "flags direct DateTime.utc_now call in domain code" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create_user(attrs) do
          now = DateTime.utc_now()
          Map.put(attrs, :created_at, now)
        end
      end
      """

      diags = assert_flagged(TimeInjection, code)
      assert hd(diags).rule_id == "1.9"
      assert hd(diags).message =~ "DateTime.utc_now"
    end

    test "allows time calls in test files" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        def setup_user do
          now = DateTime.utc_now()
          %{created_at: now}
        end
      end
      """

      assert_clean(TimeInjection, code, file: "test/accounts_test.exs")
    end

    test "allows time calls in infrastructure files" do
      code = ~S"""
      defmodule MyApp.Clock do
        def now, do: DateTime.utc_now()
      end
      """

      assert_clean(TimeInjection, code, file: "lib/my_app/clock.ex")
    end

    test "allows DateTime.utc_now in Mix tasks (operational layer)" do
      code = ~S"""
      defmodule Mix.Tasks.MyApp.Backfill do
        use Mix.Task
        def run(_) do
          now = DateTime.utc_now()
          IO.inspect(now)
        end
      end
      """

      assert_clean(TimeInjection, code, file: "lib/mix/tasks/my_app.backfill.ex")
    end

    test "allows DateTime.utc_now in a function-head default arg" do
      # FP-8: `def f(now \\ DateTime.utc_now())` IS the injection
      # mechanism the rule recommends. Production callers use the
      # default; tests pass an explicit timestamp. Flagging the
      # default arg defeats the rule's own suggested fix.
      code = ~S"""
      defmodule MyApp.Scheduler do
        def schedule(event, now \\ DateTime.utc_now()) do
          %{event: event, scheduled_at: now}
        end
      end
      """

      assert_clean(TimeInjection, code, file: "lib/my_app/scheduler.ex")
    end

    test "still flags DateTime.utc_now in body when also used as default arg" do
      # If the function uses both a default-arg injection AND a direct
      # body call, the body call is still a hardcoded clock and the
      # rule should fire.
      code = ~S"""
      defmodule MyApp.Scheduler do
        def schedule(event, now \\ DateTime.utc_now()) do
          actual_now = DateTime.utc_now()
          %{event: event, default: now, actual: actual_now}
        end
      end
      """

      diags = assert_flagged(TimeInjection, code, file: "lib/my_app/scheduler.ex")
      assert hd(diags).rule_id == "1.9"
    end
  end
end
