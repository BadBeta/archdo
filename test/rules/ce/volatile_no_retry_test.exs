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
end
