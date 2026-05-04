defmodule Archdo.AST.PredicateTest do
  use ExUnit.Case, async: true

  alias Archdo.AST.Predicate

  describe "catch_all_arg?/1" do
    test "true for the underscore wildcard" do
      assert Predicate.catch_all_arg?({:_, [], nil})
    end

    test "true for any bare variable (including _foo)" do
      assert Predicate.catch_all_arg?({:foo, [], Elixir})
      assert Predicate.catch_all_arg?({:_x, [], Elixir})
    end

    test "false for literal patterns and structured patterns" do
      refute Predicate.catch_all_arg?(:atom)
      refute Predicate.catch_all_arg?(42)
      refute Predicate.catch_all_arg?({:%{}, [], []})
    end
  end

  describe "catch_all_pattern?/1" do
    test "true for the underscore wildcard" do
      assert Predicate.catch_all_pattern?({:_, [], nil})
    end

    test "true for an ordinary variable" do
      assert Predicate.catch_all_pattern?({:foo, [], Elixir})
    end

    test "false for an underscore-prefixed variable (intentional discard)" do
      # `_foo` declares "I know I'm ignoring this" — NOT a catch-all
      # the rule should treat as shadowing.
      refute Predicate.catch_all_pattern?({:_foo, [], Elixir})
    end

    test "false for non-variable patterns" do
      refute Predicate.catch_all_pattern?(:ok)
      refute Predicate.catch_all_pattern?({:{}, [], []})
    end
  end

  describe "catch_all_terminator?/1" do
    test "true when every arg in a clause tuple is a catch-all-arg" do
      clause = {:f, 2, [], [{:_, [], nil}, {:acc, [], Elixir}], nil}
      assert Predicate.catch_all_terminator?(clause)
    end

    test "false when any arg is not a catch-all" do
      clause = {:f, 2, [], [{:_, [], nil}, :literal], nil}
      refute Predicate.catch_all_terminator?(clause)
    end

    test "false for non-clause shapes" do
      refute Predicate.catch_all_terminator?({:not_a_clause})
      refute Predicate.catch_all_terminator?(nil)
    end
  end
end
