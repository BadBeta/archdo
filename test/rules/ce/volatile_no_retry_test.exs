defmodule Archdo.Rules.CE.VolatileNoRetryTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.VolatileNoRetry

  test "fires on volatile call with no retry/breaker wrapper in scope" do
    code = ~S"""
    defmodule MyApp.Adapter do
      def fetch(url), do: Tesla.get(url)
    end
    """

    diags = assert_flagged(VolatileNoRetry, code, file: "lib/my_app/adapter.ex")
    assert hd(diags).rule_id == "CE-35"
    assert hd(diags).severity == :warning
  end

  test "does NOT fire when wrapped in Retry.with_retries" do
    code = ~S"""
    defmodule MyApp.Adapter do
      def fetch(url) do
        Retry.with_retries([attempts: 3], fn -> Tesla.get(url) end)
      end
    end
    """

    assert_clean(VolatileNoRetry, code, file: "lib/my_app/adapter.ex")
  end

  test "does NOT fire when wrapped in :fuse.ask" do
    code = ~S"""
    defmodule MyApp.Adapter do
      def fetch(url) do
        case :fuse.ask(:my_fuse, :sync) do
          :ok -> Tesla.get(url)
          :blown -> {:error, :unavailable}
        end
      end
    end
    """

    assert_clean(VolatileNoRetry, code, file: "lib/my_app/adapter.ex")
  end

  test "does NOT fire on a stable module (CE-35 is volatile-only)" do
    code = ~S"""
    defmodule MyApp.Pure do
      def normalize(s), do: URI.parse(s)
    end
    """

    assert_clean(VolatileNoRetry, code, file: "lib/my_app/pure.ex")
  end

  test "does NOT fire on `:non_deterministic` deps (clock, random) — those need injection, not retry" do
    # The rule's prescription is "wrap with retry/circuit-breaker". That's
    # appropriate for I/O / network volatility (HTTP, DB) where the call
    # may transiently fail. Clock reads (`DateTime.now!`) and random
    # (`:rand.uniform`) are NON-DETERMINISTIC but RELIABLE — they don't
    # transiently fail, they just produce different values per call. A
    # retry on `DateTime.now!` would be nonsense. The right fix is
    # capability-passing (inject the clock), not retry/circuit-breaker.
    code = ~S"""
    defmodule MyApp.Cron do
      @moduledoc false

      def next_run(timezone) when is_binary(timezone) do
        next_run(DateTime.now!(timezone))
      end

      def next_run(time) when is_struct(time, DateTime) do
        DateTime.add(time, 60, :second)
      end
    end
    """

    assert_clean(VolatileNoRetry, code, file: "lib/my_app/cron.ex")
  end
end
