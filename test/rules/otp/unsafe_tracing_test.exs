defmodule Archdo.Rules.OTP.UnsafeTracingTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.UnsafeTracing

  test "flags :dbg.tracer in production code" do
    code = ~S"""
    defmodule MyApp.Debug do
      def trace_module(mod) do
        :dbg.tracer()
        :dbg.p(:all, :c)
        :dbg.tp(mod, :_)
      end
    end
    """

    assert_flagged(UnsafeTracing, code)
  end

  test "flags :erlang.trace in production code" do
    code = ~S"""
    defmodule MyApp.Debug do
      def trace_pid(pid) do
        :erlang.trace(pid, true, [:call])
      end
    end
    """

    assert_flagged(UnsafeTracing, code)
  end

  test "ignores tracing in test files" do
    code = ~S"""
    defmodule MyApp.DebugTest do
      def trace_test do
        :dbg.tracer()
      end
    end
    """

    assert_clean(UnsafeTracing, code, file: "test/debug_test.exs")
  end

  test "allows code without tracing" do
    code = ~S"""
    defmodule MyApp.Worker do
      def process(data), do: {:ok, data}
    end
    """

    assert_clean(UnsafeTracing, code)
  end
end
