defmodule Archdo.AST.UnwrapTest do
  use ExUnit.Case, async: true

  alias Archdo.AST.Unwrap

  # The sub-module is the actual implementation behind
  # Archdo.AST.unwrap_string/1, unwrap_atom/1, unwrap_literal/1,
  # try_unwrap_atom/1 (M-CG86 split). Tests here exercise the
  # short-named public API directly.

  describe "string/1" do
    test "unwraps a literal-encoded string" do
      assert "hello" = Unwrap.string({:__block__, [], ["hello"]})
    end

    test "passes a bare binary through unchanged" do
      assert "hi" = Unwrap.string("hi")
    end

    test "returns nil for non-strings" do
      assert nil == Unwrap.string(42)
      assert nil == Unwrap.string({:foo, [], nil})
    end
  end

  describe "atom/1" do
    test "unwraps a literal-encoded atom" do
      assert :ok = Unwrap.atom({:__block__, [], [:ok]})
    end

    test "passes through non-wrapped values unchanged" do
      assert :foo = Unwrap.atom(:foo)
      assert "str" = Unwrap.atom("str")
    end
  end

  describe "try_atom/1" do
    test "returns the atom for a wrapped or bare atom" do
      assert :ok = Unwrap.try_atom({:__block__, [], [:ok]})
      assert :foo = Unwrap.try_atom(:foo)
    end

    test "returns nil for non-atoms" do
      assert nil == Unwrap.try_atom(42)
      assert nil == Unwrap.try_atom("str")
    end
  end

  describe "literal/1" do
    test "unwraps any literal-encoded value" do
      assert :ok = Unwrap.literal({:__block__, [], [:ok]})
      assert 42 = Unwrap.literal({:__block__, [], [42]})
      assert "x" = Unwrap.literal({:__block__, [], ["x"]})
    end

    test "passes non-block AST through unchanged" do
      assert {:foo, [], nil} = Unwrap.literal({:foo, [], nil})
    end
  end
end
