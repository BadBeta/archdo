defmodule Archdo.Rules.Module.NonLazyLoggerInspectTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.NonLazyLoggerInspect

  test "fires on Logger.debug with inspect inside string interpolation — non-lazy form" do
    code = ~S"""
    defmodule MyApp.Worker do
      require Logger

      def run(state) do
        Logger.debug("worker state: #{inspect(state)}")
        :ok
      end
    end
    """

    diags = assert_flagged(NonLazyLoggerInspect, code)
    assert hd(diags).rule_id == "6.85"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "lazy"
  end

  test "does NOT fire on lazy form `Logger.debug(fn -> ... end)`" do
    code = ~S"""
    defmodule MyApp.Worker do
      require Logger

      def run(state) do
        Logger.debug(fn -> "worker state: #{inspect(state)}" end)
        :ok
      end
    end
    """

    assert_clean(NonLazyLoggerInspect, code)
  end

  test "does NOT fire on Logger.info with a plain string (no inspect)" do
    code = ~S"""
    defmodule MyApp.Worker do
      require Logger

      def run do
        Logger.info("worker started")
        :ok
      end
    end
    """

    assert_clean(NonLazyLoggerInspect, code)
  end
end
