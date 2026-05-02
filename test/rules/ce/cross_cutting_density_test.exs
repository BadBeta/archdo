defmodule Archdo.Rules.CE.CrossCuttingDensityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.CrossCuttingDensity

  describe "CE-25 — function dominated by cross-cutting calls" do
    test "fires when Logger calls dominate the function body" do
      code = ~S"""
      defmodule MyApp.Worker do
        def perform(arg) do
          Logger.info("starting")
          Logger.metadata(arg: arg)
          Logger.debug("calling")
          x = do_work(arg)
          Logger.info("ok")
          Logger.debug("done")
          x
        end
      end
      """

      diags = assert_flagged(CrossCuttingDensity, code)
      assert hd(diags).rule_id == "CE-25"
      assert hd(diags).message =~ "perform/1"
      assert hd(diags).message =~ "Logger"
    end

    test "fires when telemetry calls dominate the function body" do
      code = ~S"""
      defmodule MyApp.Service do
        def call(req) do
          :telemetry.execute([:svc, :start], %{}, %{req: req})
          :telemetry.execute([:svc, :pre], %{}, %{})
          result = do_call(req)
          :telemetry.execute([:svc, :post], %{}, %{})
          :telemetry.execute([:svc, :stop], %{}, %{result: result})
          :telemetry.execute([:svc, :final], %{}, %{})
          result
        end
      end
      """

      [diag] = assert_flagged(CrossCuttingDensity, code)
      assert diag.rule_id == "CE-25"
      assert diag.message =~ ":telemetry"
    end

    test "does NOT fire on tiny function (< 5 expressions)" do
      code = ~S"""
      defmodule MyApp.Tiny do
        def perform(arg) do
          Logger.info("hi")
          do_work(arg)
        end
      end
      """

      assert_clean(CrossCuttingDensity, code)
    end

    test "does NOT fire when cross-cutting density is below threshold" do
      code = ~S"""
      defmodule MyApp.Mostly do
        def work(x) do
          a = compute_a(x)
          b = compute_b(a)
          c = compute_c(b)
          d = compute_d(c)
          e = compute_e(d)
          Logger.info("done")
          e
        end
      end
      """

      assert_clean(CrossCuttingDensity, code)
    end

    test "does NOT fire when @archdo_aspect_aggregator true" do
      code = ~S"""
      defmodule MyApp.Wrapper do
        @archdo_aspect_aggregator true
        def with_logging(name, fun) do
          Logger.info("start " <> name)
          Logger.metadata(op: name)
          result = fun.()
          Logger.metadata(op: nil)
          Logger.info("end " <> name)
          Logger.debug("returning")
          result
        end
      end
      """

      assert_clean(CrossCuttingDensity, code)
    end

    test "lists which cross-cutting concerns are concentrating" do
      code = ~S"""
      defmodule MyApp.Mixed do
        def perform(arg) do
          Logger.info("start")
          :telemetry.execute([:e], %{}, %{})
          Repo.transaction(fn -> do_work(arg) end)
          Logger.info("end")
          :telemetry.execute([:f], %{}, %{})
          :ok
        end
      end
      """

      [diag] = assert_flagged(CrossCuttingDensity, code)
      # Should mention multiple categories that contribute
      msg = diag.message
      assert msg =~ "Logger" or msg =~ ":telemetry" or msg =~ "Repo"
    end
  end
end
