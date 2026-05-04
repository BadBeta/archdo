defmodule Archdo.Rules.CE.PipelineOrderFlipTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.PipelineOrderFlip

  describe "fires when arity-2 function flips its input order on output" do
    test "(integer, atom) :: {atom, integer}" do
      code = ~S"""
      defmodule MyApp.Swap do
        @spec swap(integer(), atom()) :: {atom(), integer()}
        def swap(a, b), do: {b, a}
      end
      """

      diags = assert_flagged(PipelineOrderFlip, code)
      assert hd(diags).rule_id == "CE-58"
      assert hd(diags).severity == :info
      assert hd(diags).message =~ "swap"
    end

    test "(String.t, integer) :: {integer, String.t}" do
      code = ~S"""
      defmodule MyApp.Pair do
        @spec at(String.t(), integer()) :: {integer(), String.t()}
        def at(s, i), do: {i, s}
      end
      """

      diags = assert_flagged(PipelineOrderFlip, code)
      assert hd(diags).rule_id == "CE-58"
    end
  end

  describe "does NOT fire" do
    test "input and output share types but in the same order" do
      code = ~S"""
      defmodule MyApp.Plain do
        @spec coords(integer(), integer()) :: {integer(), integer()}
        def coords(a, b), do: {a, b}
      end
      """

      assert_clean(PipelineOrderFlip, code)
    end

    test "return type is not a tuple" do
      code = ~S"""
      defmodule MyApp.Sum do
        @spec add(integer(), integer()) :: integer()
        def add(a, b), do: a + b
      end
      """

      assert_clean(PipelineOrderFlip, code)
    end

    test "return type has different arity than input" do
      code = ~S"""
      defmodule MyApp.Tri do
        @spec wrap(integer(), atom()) :: {integer(), atom(), :marker}
        def wrap(a, b), do: {a, b, :marker}
      end
      """

      assert_clean(PipelineOrderFlip, code)
    end

    test "return type is a different multiset" do
      code = ~S"""
      defmodule MyApp.Mixed do
        @spec convert(integer(), atom()) :: {String.t(), boolean()}
        def convert(_a, _b), do: {"x", true}
      end
      """

      assert_clean(PipelineOrderFlip, code)
    end

    test "function has no @spec" do
      code = ~S"""
      defmodule MyApp.NoSpec do
        def swap(a, b), do: {b, a}
      end
      """

      assert_clean(PipelineOrderFlip, code)
    end

    test "function is private" do
      code = ~S"""
      defmodule MyApp.Internal do
        @spec swap(integer(), atom()) :: {atom(), integer()}
        defp swap(a, b), do: {b, a}
      end
      """

      assert_clean(PipelineOrderFlip, code)
    end

    test "test files are skipped" do
      code = ~S"""
      defmodule MyApp.SwapTest do
        @spec swap(integer(), atom()) :: {atom(), integer()}
        def swap(a, b), do: {b, a}
      end
      """

      assert_clean(PipelineOrderFlip, code, file: "test/my_app/swap_test.exs")
    end
  end

  describe "higher arities" do
    test "arity-3 fires when output is a permutation of input" do
      code = ~S"""
      defmodule MyApp.Triple do
        @spec rotate(integer(), atom(), String.t()) :: {String.t(), integer(), atom()}
        def rotate(a, b, c), do: {c, a, b}
      end
      """

      diags = assert_flagged(PipelineOrderFlip, code)
      assert hd(diags).rule_id == "CE-58"
    end

    test "arity-3 does not fire when output preserves input order" do
      code = ~S"""
      defmodule MyApp.Triple do
        @spec same(integer(), atom(), String.t()) :: {integer(), atom(), String.t()}
        def same(a, b, c), do: {a, b, c}
      end
      """

      assert_clean(PipelineOrderFlip, code)
    end

    test "arity-4 fires when output is a permutation of input" do
      code = ~S"""
      defmodule MyApp.Quad do
        @spec shuffle(integer(), atom(), String.t(), boolean()) ::
                {boolean(), String.t(), atom(), integer()}
        def shuffle(a, b, c, d), do: {d, c, b, a}
      end
      """

      diags = assert_flagged(PipelineOrderFlip, code)
      assert hd(diags).rule_id == "CE-58"
    end
  end
end
