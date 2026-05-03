defmodule Archdo.PipeRewriterTest do
  use ExUnit.Case, async: true

  alias Archdo.PipeRewriter

  describe "rewrite/2 — call with args" do
    test "Module.fun(arg) — prepends input as first arg" do
      assert PipeRewriter.rewrite("foo", "Mod.bar(x)") == "Mod.bar(foo, x)"
    end

    test "Module.fun() — input becomes the only arg" do
      assert PipeRewriter.rewrite("foo", "Mod.bar()") == "Mod.bar(foo)"
    end

    test "nested module path Mod.Sub.fun(arg)" do
      assert PipeRewriter.rewrite("foo", "A.B.C.bar(x)") == "A.B.C.bar(foo, x)"
    end

    test "local function call bar(x)" do
      assert PipeRewriter.rewrite("foo", "bar(x)") == "bar(foo, x)"
    end

    test "predicate function on a multi-segment module Mod.Sub.bar?()" do
      # The regex only accepts ? / ! in the OPTIONAL trailing segment,
      # which requires a leading `.<segment>`. So `bar?()` standalone
      # is NOT handled — only nested-module-qualified calls.
      assert PipeRewriter.rewrite("foo", "Mod.Sub.bar?()") == "Mod.Sub.bar?(foo)"
    end

    test "bang function on a multi-segment module Mod.Sub.bar!(x)" do
      assert PipeRewriter.rewrite("foo", "Mod.Sub.bar!(x)") == "Mod.Sub.bar!(foo, x)"
    end

    test "local predicate bar?() returns nil — regex limitation" do
      # Existing behavior: local predicates aren't handled. Documented
      # here so a refactor preserves the surface area.
      assert PipeRewriter.rewrite("foo", "bar?()") == nil
    end

    test "local bang bar!(x) returns nil — regex limitation" do
      assert PipeRewriter.rewrite("foo", "bar!(x)") == nil
    end

    test "multiple existing args" do
      assert PipeRewriter.rewrite("foo", "Mod.bar(x, y, z)") == "Mod.bar(foo, x, y, z)"
    end
  end

  describe "rewrite/2 — bare name (no parens)" do
    test "bare local name" do
      assert PipeRewriter.rewrite("foo", "bar") == "bar(foo)"
    end

    test "bare module-qualified name" do
      assert PipeRewriter.rewrite("foo", "Mod.bar") == "Mod.bar(foo)"
    end

    test "bare predicate Mod.Sub.bar? on a multi-segment module" do
      # As with parenthesized predicates: ? requires the optional trailing
      # segment, so only nested-module forms work.
      assert PipeRewriter.rewrite("foo", "Mod.Sub.bar?") == "Mod.Sub.bar?(foo)"
    end

    test "local bare predicate bar? returns nil — regex limitation" do
      assert PipeRewriter.rewrite("foo", "bar?") == nil
    end
  end

  describe "rewrite/2 — non-matching shapes return nil" do
    test "operator string" do
      assert PipeRewriter.rewrite("foo", "+ 1") == nil
    end

    test "anonymous function call" do
      # Doesn't match the named-call regex.
      assert PipeRewriter.rewrite("foo", "(fn x -> x end).()") == nil
    end
  end

  describe "rewrite_line/1" do
    test "rewrites simple pipe to direct call" do
      assert PipeRewriter.rewrite_line("foo |> bar()") == "bar(foo)"
    end

    test "rewrites Module.fun pipe with args" do
      assert PipeRewriter.rewrite_line("foo |> Mod.bar(x)") == "Mod.bar(foo, x)"
    end

    test "returns nil for line without pipe" do
      assert PipeRewriter.rewrite_line("foo + bar") == nil
    end

    test "returns nil when input is not safe to rewrite" do
      # Multi-statement input — not safe.
      assert PipeRewriter.rewrite_line("foo = compute(); foo |> bar()") == nil
    end
  end

  describe "safe_to_rewrite?/2" do
    test "bare variable is safe" do
      assert PipeRewriter.safe_to_rewrite?("foo", "any line")
    end

    test "local function call is safe" do
      assert PipeRewriter.safe_to_rewrite?("foo()", "any line")
      assert PipeRewriter.safe_to_rewrite?("foo(x, y)", "any line")
    end

    test "Module.fun() is safe" do
      assert PipeRewriter.safe_to_rewrite?("Mod.fun()", "any line")
      assert PipeRewriter.safe_to_rewrite?("A.B.C.fun(x)", "any line")
    end

    test "list literal is safe" do
      assert PipeRewriter.safe_to_rewrite?("[1, 2, 3]", "any line")
    end

    test "assignment is NOT safe" do
      refute PipeRewriter.safe_to_rewrite?("foo = bar", "any line")
    end

    test "operator expression is NOT safe" do
      refute PipeRewriter.safe_to_rewrite?("a + b", "any line")
    end

    test "multi-statement appears safe — regex limitation, documented" do
      # Existing behavior: the call regex `^[a-z_]\w*\(.*\)$` is greedy
      # and matches `foo(); bar()` as if it were one call. Latent bug,
      # preserved here so a refactor doesn't silently change it.
      assert PipeRewriter.safe_to_rewrite?("foo(); bar()", "any line")
    end
  end
end
