defmodule Archdo.Rules.CE.AcquireReleaseTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.AcquireRelease

  test "fires on public open/close pair without with_X bracket" do
    code = ~S"""
    defmodule MyApp.Resource do
      def open(arg), do: do_open(arg)
      def close(handle), do: do_close(handle)
    end
    """

    diags = assert_flagged(AcquireRelease, code)
    assert hd(diags).rule_id == "CE-21"
    assert hd(diags).message =~ "open/close"
  end

  test "does NOT fire when a with_X bracket exists" do
    code = ~S"""
    defmodule MyApp.Resource do
      def open(arg), do: do_open(arg)
      def close(handle), do: do_close(handle)

      def with_resource(arg, fun) do
        resource = open(arg)
        try do
          fun.(resource)
        after
          close(resource)
        end
      end
    end
    """

    assert_clean(AcquireRelease, code)
  end

  test "fires on acquire/release pair" do
    code = ~S"""
    defmodule MyApp.Lock do
      def acquire(name), do: do_acquire(name)
      def release(handle), do: do_release(handle)
    end
    """

    assert [diag] = assert_flagged(AcquireRelease, code)
    assert diag.message =~ "acquire/release"
  end

  test "fires on subscribe/unsubscribe pair" do
    code = ~S"""
    defmodule MyApp.Topic do
      def subscribe(topic), do: do_subscribe(topic)
      def unsubscribe(topic), do: do_unsubscribe(topic)
    end
    """

    assert [diag] = assert_flagged(AcquireRelease, code)
    assert diag.message =~ "subscribe/unsubscribe"
  end

  test "does NOT fire on start_link/stop pair (long-lived process exemption)" do
    code = ~S"""
    defmodule MyApp.Worker do
      use GenServer
      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
      def stop(pid), do: GenServer.stop(pid)
    end
    """

    assert_clean(AcquireRelease, code)
  end
end
