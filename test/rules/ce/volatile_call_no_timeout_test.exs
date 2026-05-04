defmodule Archdo.Rules.CE.VolatileCallNoTimeoutTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.VolatileCallNoTimeout

  test "fires on Tesla.get/1 without :timeout option" do
    code = ~S"""
    defmodule MyApp.Adapter do
      def fetch(url), do: Tesla.get(url)
    end
    """

    diags = assert_flagged(VolatileCallNoTimeout, code, file: "lib/my_app/adapter.ex")
    assert hd(diags).rule_id == "CE-34"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "Tesla.get"
  end

  test "does NOT fire when :recv_timeout is set in options" do
    code = ~S"""
    defmodule MyApp.Adapter do
      def fetch(url), do: Tesla.get(url, opts: [recv_timeout: 5_000])
    end
    """

    assert_clean(VolatileCallNoTimeout, code, file: "lib/my_app/adapter.ex")
  end

  test "fires on GenServer.call/2 without explicit timeout (implicit 5s default)" do
    code = ~S"""
    defmodule MyApp.Worker do
      def status(pid), do: GenServer.call(pid, :status)
    end
    """

    diags = assert_flagged(VolatileCallNoTimeout, code, file: "lib/my_app/worker.ex")
    assert Enum.any?(diags, &(&1.message =~ "GenServer.call"))
  end

  test "does NOT fire on a stable module (CE-34 is volatile-only)" do
    code = ~S"""
    defmodule MyApp.Pure do
      def normalize(s), do: URI.parse(s)
    end
    """

    assert_clean(VolatileCallNoTimeout, code, file: "lib/my_app/pure.ex")
  end

  test "does NOT fire on Req.new/0,1 — request-builder, not HTTP call" do
    code = ~S"""
    defmodule MyApp.Volatile do
      def build do
        Req.new(base_url: "https://example.com")
      end
    end
    """

    assert_clean(VolatileCallNoTimeout, code, file: "lib/my_app/volatile.ex")
  end

  test "does NOT fire on Finch.build/3 — request-builder, not HTTP call" do
    code = ~S"""
    defmodule MyApp.Volatile do
      def build_get(url) do
        Finch.build(:get, url)
      end
    end
    """

    assert_clean(VolatileCallNoTimeout, code, file: "lib/my_app/volatile.ex")
  end

  test "fires on Req.get/2 without timeout option (real HTTP call)" do
    code = ~S"""
    defmodule MyApp.Volatile do
      def fetch(url) do
        Req.get(url)
      end
    end
    """

    assert_flagged(VolatileCallNoTimeout, code, file: "lib/my_app/volatile.ex")
  end
end
