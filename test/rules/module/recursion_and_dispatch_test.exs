defmodule Archdo.Rules.Module.RecursionAndDispatchTest do
  use Archdo.RuleCase

  describe "6.19 IfElseDispatch" do
    alias Archdo.Rules.Module.IfElseDispatch

    test "flags if/else with is_map type guard" do
      code = ~S"""
      defmodule MyApp.Handler do
        def process(data) do
          if is_map(data) do
            handle_map(data)
          else
            handle_other(data)
          end
        end
      end
      """

      diags = assert_flagged(IfElseDispatch, code)
      assert hd(diags).rule_id == "6.19"
    end

    test "flags if/else with nil check returning values" do
      code = ~S"""
      defmodule MyApp.Handler do
        def process(data) do
          if data != nil do
            transform(data)
          else
            default()
          end
        end
      end
      """

      diags = assert_flagged(IfElseDispatch, code)
      assert hd(diags).rule_id == "6.19"
    end

    test "allows if without else (side-effect only)" do
      code = ~S"""
      defmodule MyApp.Logger do
        def maybe_log(data) do
          if is_map(data) do
            Logger.info("got map")
          end
        end
      end
      """

      assert_clean(IfElseDispatch, code)
    end

    test "allows case for dispatch" do
      code = ~S"""
      defmodule MyApp.Handler do
        def process(data) do
          case data do
            %{} -> handle_map(data)
            _ -> handle_other(data)
          end
        end
      end
      """

      assert_clean(IfElseDispatch, code)
    end

    test "allows simple boolean if" do
      code = ~S"""
      defmodule MyApp.Handler do
        def check(user) do
          if user.active do
            {:ok, user}
          else
            {:error, :inactive}
          end
        end
      end
      """

      assert_clean(IfElseDispatch, code)
    end
  end

  describe "6.20 NonTailRecursion" do
    alias Archdo.Rules.Module.NonTailRecursion

    test "flags [head | recurse(tail)] pattern" do
      code = ~S"""
      defmodule MyApp.Transform do
        def double([head | tail]) do
          [head * 2 | double(tail)]
        end

        def double([]), do: []
      end
      """

      diags = assert_flagged(NonTailRecursion, code)
      assert hd(diags).rule_id == "6.20"
    end

    test "allows tail-recursive with accumulator" do
      code = ~S"""
      defmodule MyApp.Transform do
        def double(list), do: do_double(list, [])

        defp do_double([], acc), do: Enum.reverse(acc)
        defp do_double([head | tail], acc), do: do_double(tail, [head * 2 | acc])
      end
      """

      assert_clean(NonTailRecursion, code)
    end

    test "allows non-recursive functions" do
      code = ~S"""
      defmodule MyApp.Math do
        def add(a, b), do: a + b
      end
      """

      assert_clean(NonTailRecursion, code)
    end

    test "allows shape walkers (multi-clause tuple destructure + catch-all terminator)" do
      # Canonical Elixir AST walker: pattern matches on tuple shapes,
      # recurses on parts, terminates via def f(_), do: <literal>.
      # Stack depth is bounded by input-tree depth, not by user input.
      code = ~S"""
      defmodule MyApp.AST do
        def size(nil), do: 0
        def size({_form, _meta, args}), do: 1 + size(args)
        def size({a, b}), do: 1 + size(a) + size(b)
        def size(list) when is_list(list), do: Enum.sum(Enum.map(list, &size/1))
        def size(_), do: 1
      end
      """

      assert_clean(NonTailRecursion, code)
    end
  end

  describe "6.21 UnnecessaryRecursion" do
    alias Archdo.Rules.Module.UnnecessaryRecursion

    test "flags manual list recursion" do
      code = ~S"""
      defmodule MyApp.Utils do
        def process([head | tail]) do
          result = transform(head)
          [result | process(tail)]
        end

        def process([]), do: []
      end
      """

      diags = assert_flagged(UnnecessaryRecursion, code)
      assert hd(diags).rule_id == "6.21"
    end

    test "allows Enum.map usage" do
      code = ~S"""
      defmodule MyApp.Utils do
        def process(list) do
          Enum.map(list, &transform/1)
        end
      end
      """

      assert_clean(UnnecessaryRecursion, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.UtilsTest do
        def helper([head | tail]), do: [head | helper(tail)]
        def helper([]), do: []
      end
      """

      assert_clean(UnnecessaryRecursion, code, file: "test/utils_test.exs")
    end
  end
end
