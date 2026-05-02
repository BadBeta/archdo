defmodule Archdo.Rules.CE.UnguardedBuildingBlockTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.UnguardedBuildingBlock

  describe "CE-57 — building-block candidate accepts unguarded input" do
    test "fires on a single-clause function with bare-variable args (no guards)" do
      # Trivial pure function — high Blackbox score, but `discount("foo", :bar)`
      # crashes deep in the body instead of returning a controlled error.
      code = ~S"""
      defmodule MyApp.Pricing do
        @spec discount(integer(), float()) :: integer()
        def discount(price, rate), do: max(0, price - round(price * rate))
      end
      """

      diags = assert_flagged(UnguardedBuildingBlock, code)
      assert hd(diags).rule_id == "CE-57"
      assert hd(diags).message =~ "discount/2"
    end

    test "does NOT fire when function head has guards" do
      code = ~S"""
      defmodule MyApp.Pricing do
        @spec discount(integer(), float()) :: integer()
        def discount(price, rate) when is_integer(price) and is_number(rate) do
          max(0, price - round(price * rate))
        end
      end
      """

      assert_clean(UnguardedBuildingBlock, code)
    end

    test "does NOT fire when all clauses pattern-match specific shapes" do
      code = ~S"""
      defmodule MyApp.Status do
        @spec describe(:active | :inactive | :pending) :: String.t()
        def describe(:active), do: "Active"
        def describe(:inactive), do: "Inactive"
        def describe(:pending), do: "Pending"
      end
      """

      assert_clean(UnguardedBuildingBlock, code)
    end

    test "does NOT fire when a fallback clause returns {:error, _}" do
      code = ~S"""
      defmodule MyApp.Parser do
        @spec parse(String.t()) :: {:ok, integer()} | {:error, :invalid}
        def parse(s) when is_binary(s) do
          case Integer.parse(s) do
            {n, ""} -> {:ok, n}
            _ -> {:error, :invalid}
          end
        end

        def parse(_), do: {:error, :invalid_input}
      end
      """

      assert_clean(UnguardedBuildingBlock, code)
    end

    test "does NOT fire on non-candidate functions (low Blackbox score)" do
      # Function with side-effect — not a building-block candidate to begin with
      code = ~S"""
      defmodule MyApp.Logger do
        def log(msg) do
          Logger.info(msg)
          :ok
        end
      end
      """

      assert_clean(UnguardedBuildingBlock, code)
    end

    test "does NOT fire when @archdo_no_input_check marker is set" do
      code = ~S"""
      defmodule MyApp.Trusted do
        @archdo_no_input_check "all callers pre-validate via the context boundary"

        @spec compute(integer()) :: integer()
        def compute(x), do: x * 2
      end
      """

      assert_clean(UnguardedBuildingBlock, code)
    end

    test "does NOT fire on zero-arity function (no inputs to constrain)" do
      code = ~S"""
      defmodule MyApp.Constants do
        @spec pi() :: float()
        def pi, do: 3.14159
      end
      """

      assert_clean(UnguardedBuildingBlock, code)
    end

    test "fires when only one clause is guarded but a bare-arg clause also exists" do
      # Mixed: guarded path + bare-arg fallback that DOESN'T return {:error, _}.
      # The bare-arg fallback re-introduces the unguarded-input problem.
      code = ~S"""
      defmodule MyApp.Mixed do
        @spec process(integer()) :: integer()
        def process(x) when is_integer(x), do: x * 2
        def process(x), do: x
      end
      """

      diags = assert_flagged(UnguardedBuildingBlock, code)
      assert hd(diags).rule_id == "CE-57"
    end
  end

  describe "pack assignment" do
    test "rule pack is :ce_composability (opt-in)" do
      assert UnguardedBuildingBlock.pack() == :ce_composability
    end
  end
end
