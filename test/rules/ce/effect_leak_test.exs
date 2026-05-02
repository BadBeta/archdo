defmodule Archdo.Rules.CE.EffectLeakTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.EffectLeak

  describe "CE-56 — near-blackbox function with single observability effect" do
    test "fires when only side-effect is a Logger call" do
      code = ~S"""
      defmodule MyApp.Pricing do
        @spec discount(integer(), float()) :: integer()
        def discount(price, rate) do
          Logger.info("computing discount", price: price, rate: rate)
          max(0, price - round(price * rate))
        end
      end
      """

      diags = assert_flagged(EffectLeak, code)
      assert hd(diags).rule_id == "CE-56"
      assert hd(diags).message =~ "discount/2"
      assert hd(diags).message =~ "Logger"
    end

    test "fires when only side-effect is :telemetry.execute" do
      code = ~S"""
      defmodule MyApp.Service do
        @spec compute(integer()) :: integer()
        def compute(x) do
          :telemetry.execute([:my_app, :compute], %{value: x}, %{})
          x * 2
        end
      end
      """

      [diag] = assert_flagged(EffectLeak, code)
      assert diag.rule_id == "CE-56"
      assert diag.message =~ ":telemetry"
    end

    test "fires when only side-effect is Phoenix.PubSub.broadcast" do
      code = ~S"""
      defmodule MyApp.Topic do
        @spec announce(String.t()) :: :ok
        def announce(msg) do
          Phoenix.PubSub.broadcast(MyApp.PubSub, "announcements", msg)
          :ok
        end
      end
      """

      [diag] = assert_flagged(EffectLeak, code)
      assert diag.rule_id == "CE-56"
    end

    test "does NOT fire when function is already a building block (no leak)" do
      code = ~S"""
      defmodule MyApp.Pricing do
        @spec discount(integer(), float()) :: integer()
        def discount(price, rate), do: max(0, price - round(price * rate))
      end
      """

      assert_clean(EffectLeak, code)
    end

    test "does NOT fire when other components also fail (full refactor needed)" do
      # Missing @spec drops output_completeness — multi-component failure,
      # not a single leak.
      code = ~S"""
      defmodule MyApp.Bad do
        def call(x) do
          Logger.info("hi")
          x
        end
      end
      """

      assert_clean(EffectLeak, code)
    end

    test "does NOT fire when side-effect is non-observability (e.g. Repo.insert)" do
      code = ~S"""
      defmodule MyApp.Persist do
        @spec save(map()) :: {:ok, map()}
        def save(attrs) do
          Repo.insert(attrs)
          {:ok, attrs}
        end
      end
      """

      assert_clean(EffectLeak, code)
    end

    test "does NOT fire when there are 3+ side-effects (not 'single leak')" do
      code = ~S"""
      defmodule MyApp.LogHeavy do
        @spec process(integer()) :: integer()
        def process(x) do
          Logger.info("start")
          Logger.debug("processing")
          Logger.info("done")
          Logger.error("just kidding")
          x
        end
      end
      """

      assert_clean(EffectLeak, code)
    end

    test "does NOT fire when @archdo_no_property is set" do
      code = ~S"""
      defmodule MyApp.MustLog do
        @archdo_no_property "logging is the function's job"

        @spec emit(String.t()) :: :ok
        def emit(msg) do
          Logger.info(msg)
          :ok
        end
      end
      """

      assert_clean(EffectLeak, code)
    end
  end

  describe "pack assignment" do
    test "rule pack is :ce_composability (opt-in)" do
      assert EffectLeak.pack() == :ce_composability
    end
  end
end
