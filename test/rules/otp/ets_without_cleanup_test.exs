defmodule Archdo.Rules.OTP.EtsWithoutCleanupTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.EtsWithoutCleanup

  describe "analyze/3" do
    test "flags :ets.new with :named_table but no cleanup" do
      code = ~S"""
      defmodule MyApp.Cache do
        use GenServer

        def init(_) do
          :ets.new(:cache, [:set, :public, :named_table])
          {:ok, %{}}
        end
      end
      """

      diags = assert_flagged(EtsWithoutCleanup, code)
      diag = hd(diags)
      assert diag.severity == :info
      assert diag.rule_id == "5.45"
    end

    test "allows :ets.new with :named_table when terminate/2 exists" do
      code = ~S"""
      defmodule MyApp.Cache do
        use GenServer

        def init(_) do
          :ets.new(:cache, [:set, :public, :named_table])
          {:ok, %{}}
        end

        def terminate(_reason, _state) do
          :ets.delete(:cache)
          :ok
        end
      end
      """

      assert_clean(EtsWithoutCleanup, code)
    end

    test "allows :ets.new with :named_table when :ets.delete exists" do
      code = ~S"""
      defmodule MyApp.Cache do
        use GenServer

        def init(_) do
          :ets.new(:cache, [:set, :public, :named_table])
          {:ok, %{}}
        end

        def handle_call(:clear, _from, state) do
          :ets.delete(:cache)
          {:reply, :ok, state}
        end
      end
      """

      assert_clean(EtsWithoutCleanup, code)
    end

    test "allows :ets.new without :named_table" do
      code = ~S"""
      defmodule MyApp.Worker do
        def init(_) do
          table = :ets.new(:temp, [:set, :public])
          {:ok, %{table: table}}
        end
      end
      """

      assert_clean(EtsWithoutCleanup, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.CacheTest do
        use ExUnit.Case

        test "creates table" do
          :ets.new(:test_cache, [:set, :public, :named_table])
        end
      end
      """

      assert_clean(EtsWithoutCleanup, code, file: "test/cache_test.exs")
    end
  end
end
