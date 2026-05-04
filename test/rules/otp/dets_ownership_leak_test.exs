defmodule Archdo.Rules.OTP.DetsOwnershipLeakTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.DetsOwnershipLeak

  describe "analyze/3" do
    test "flags a GenServer that opens a DETS table without terminate/2" do
      code = ~S"""
      defmodule MyApp.Cache do
        use GenServer

        def init(_) do
          {:ok, t} = :dets.open_file(:my_cache, file: ~c"/tmp/cache.dets")
          {:ok, %{table: t}}
        end
      end
      """

      diags = assert_flagged(DetsOwnershipLeak, code)
      assert hd(diags).rule_id == "5.47"
      assert hd(diags).message =~ "DETS"
      assert hd(diags).message =~ "terminate"
    end

    test "allows a GenServer with terminate/2 that closes the DETS table" do
      code = ~S"""
      defmodule MyApp.Cache do
        use GenServer

        def init(_) do
          {:ok, t} = :dets.open_file(:my_cache, file: ~c"/tmp/cache.dets")
          {:ok, %{table: t}}
        end

        def terminate(_reason, %{table: t}) do
          :dets.close(t)
          :ok
        end
      end
      """

      assert_clean(DetsOwnershipLeak, code)
    end

    test "allows a GenServer with terminate/2 (any terminate is enough)" do
      # Mirror EtsOwnershipLeak's heuristic — having any terminate/2
      # callback is treated as evidence of cleanup awareness.
      code = ~S"""
      defmodule MyApp.Cache do
        use GenServer

        def init(_), do: :dets.open_file(:my_cache, file: ~c"/tmp/cache.dets")

        def terminate(_reason, _state) do
          :ok
        end
      end
      """

      assert_clean(DetsOwnershipLeak, code)
    end

    test "does not flag a non-GenServer module that opens DETS" do
      # A plain module opening DETS isn't a long-lived owner — it's
      # a short-lived one-shot. The rule's premise (table outlives a
      # supervised process restart) doesn't apply.
      code = ~S"""
      defmodule MyApp.Migrate do
        def run do
          :dets.open_file(:tmp, file: ~c"/tmp/migrate.dets")
        end
      end
      """

      assert_clean(DetsOwnershipLeak, code)
    end

    test "does not flag GenServers that don't open DETS" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer
        def init(_), do: {:ok, %{}}
      end
      """

      assert_clean(DetsOwnershipLeak, code)
    end

    test "ignores test files" do
      code = ~S"""
      defmodule MyApp.CacheTest do
        use GenServer

        def init(_), do: :dets.open_file(:my_cache, [])
      end
      """

      assert_clean(DetsOwnershipLeak, code, file: "test/cache_test.exs")
    end
  end
end
