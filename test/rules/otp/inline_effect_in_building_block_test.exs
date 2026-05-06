defmodule Archdo.Rules.OTP.InlineEffectInBuildingBlockTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.InlineEffectInBuildingBlock

  describe "inline effect in building-block module" do
    test "flags Logger call inside a building-block module" do
      code = ~S"""
      defmodule MyApp.Pricing do
        @moduledoc "Building block: pure pricing functions."

        require Logger

        def discount(price, rate) do
          Logger.info("calculating discount")
          price * (1 - rate)
        end
      end
      """

      [diag] = assert_flagged(InlineEffectInBuildingBlock, code)
      assert diag.rule_id == "5.74"
      assert diag.severity == :info
      assert diag.message =~ "Logger"
    end

    test "flags Phoenix.PubSub.broadcast inside a building-block module" do
      code = ~S"""
      defmodule MyApp.Counter do
        @moduledoc "Building-block: integer arithmetic."

        def increment(state, n) do
          Phoenix.PubSub.broadcast(MyApp.PubSub, "counter", {:incr, n})
          state + n
        end
      end
      """

      [diag] = assert_flagged(InlineEffectInBuildingBlock, code)
      assert diag.message =~ "PubSub"
    end

    test "flags Repo.insert inside a building-block module" do
      code = ~S"""
      defmodule MyApp.Validator do
        @moduledoc "BUILDING BLOCK — validation rules."

        def run(attrs) do
          MyApp.Repo.insert(%Audit{action: "ran"})
          :ok
        end
      end
      """

      [diag] = assert_flagged(InlineEffectInBuildingBlock, code)
      assert diag.message =~ "Repo"
    end

    test "flags :telemetry.execute inside a building-block module" do
      code = ~S"""
      defmodule MyApp.Calc do
        @moduledoc "building block — math helpers"

        def compute(x) do
          :telemetry.execute([:my_app, :calc], %{value: x}, %{})
          x * 2
        end
      end
      """

      [diag] = assert_flagged(InlineEffectInBuildingBlock, code)
      assert diag.message =~ "telemetry"
    end

    test "flags :ets.insert inside a building-block module" do
      code = ~S"""
      defmodule MyApp.Cache do
        @moduledoc "Building block — pure cache key functions."

        def put(key, value) do
          :ets.insert(:my_cache, {key, value})
          :ok
        end
      end
      """

      [diag] = assert_flagged(InlineEffectInBuildingBlock, code)
      assert diag.message =~ "ets"
    end

    test "flags multiple effects in same module (one diag per effect)" do
      code = ~S"""
      defmodule MyApp.Service do
        @moduledoc "Building block: business logic."

        require Logger

        def call(x) do
          Logger.info("call")
          :telemetry.execute([:e], %{}, %{})
          x
        end
      end
      """

      diagnostics = assert_flagged(InlineEffectInBuildingBlock, code)
      assert length(diagnostics) == 2
    end
  end

  describe "clean code" do
    test "does not flag effect in non-building-block module" do
      code = ~S"""
      defmodule MyApp.Orchestrator do
        @moduledoc "Orchestrates pricing + audit logging."

        require Logger

        def call(x) do
          Logger.info("call")
          x
        end
      end
      """

      assert_clean(InlineEffectInBuildingBlock, code)
    end

    test "does not flag pure building-block module" do
      code = ~S"""
      defmodule MyApp.Pricing do
        @moduledoc "Building block: pure pricing functions."

        def discount(price, rate), do: price * (1 - rate)
      end
      """

      assert_clean(InlineEffectInBuildingBlock, code)
    end

    test "does not flag building-block module without @moduledoc" do
      # If there's no moduledoc, we can't classify it as a building-block.
      code = ~S"""
      defmodule MyApp.Util do
        require Logger
        def call(x) do
          Logger.info("x")
          x
        end
      end
      """

      assert_clean(InlineEffectInBuildingBlock, code)
    end

    test "does not flag building-block module with `@moduledoc false`" do
      code = ~S"""
      defmodule MyApp.Internal do
        @moduledoc false

        require Logger
        def call(x) do
          Logger.info("x")
          x
        end
      end
      """

      assert_clean(InlineEffectInBuildingBlock, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.PricingTest do
        @moduledoc "Building block tests."

        require Logger

        def helper(x) do
          Logger.info("test")
          x
        end
      end
      """

      assert_clean(InlineEffectInBuildingBlock, code, file: "test/pricing_test.exs")
    end
  end

  describe "edge cases" do
    test "matches `building-block` (hyphenated) and `building block` (space)" do
      code1 = ~S"""
      defmodule X do
        @moduledoc "building-block: x"
        require Logger
        def f(x), do: Logger.info(inspect(x))
      end
      """

      code2 = ~S"""
      defmodule Y do
        @moduledoc "building block: y"
        require Logger
        def f(x), do: Logger.info(inspect(x))
      end
      """

      assert_flagged(InlineEffectInBuildingBlock, code1)
      assert_flagged(InlineEffectInBuildingBlock, code2)
    end
  end
end
