defmodule Archdo.Rules.Module.TelemetryInRecursiveFunctionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.TelemetryInRecursiveFunction

  test "fires when :telemetry.execute is a top-level sibling of a recursive self-call" do
    code = ~S"""
    defmodule MyApp.Loop do
      def loop(0), do: :ok

      def loop(n) do
        :telemetry.execute([:my_app, :tick], %{n: n}, %{})
        loop(n - 1)
      end
    end
    """

    diags = assert_flagged(TelemetryInRecursiveFunction, code)
    assert hd(diags).rule_id == "6.58"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "telemetry"
  end

  test "does NOT fire when telemetry is guarded by an `if` (only one iteration emits)" do
    code = ~S"""
    defmodule MyApp.Loop do
      def loop(0, _), do: :ok

      def loop(n, first?) do
        if first? do
          :telemetry.execute([:my_app, :start], %{n: n}, %{})
        end

        loop(n - 1, false)
      end
    end
    """

    assert_clean(TelemetryInRecursiveFunction, code)
  end

  test "does NOT fire on a function that emits telemetry but does not recurse" do
    code = ~S"""
    defmodule MyApp.Once do
      def emit do
        :telemetry.execute([:my_app, :event], %{}, %{})
        :ok
      end
    end
    """

    assert_clean(TelemetryInRecursiveFunction, code)
  end
end
