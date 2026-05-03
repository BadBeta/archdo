defmodule Archdo.Rules.Module.UnboundedRecursionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.UnboundedRecursion

  describe "analyze/3" do
    test "flags non-tail recursion without base case or depth guard" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          {token, rest} = next_token(input)
          [token | parse(rest)]
        end
      end
      """

      diags = assert_flagged(UnboundedRecursion, code)
      assert hd(diags).rule_id == "6.23"
      assert hd(diags).message =~ "depth"
    end

    test "allows recursion with empty list base case" do
      code = ~S"""
      defmodule MyApp.Transform do
        def double([head | tail]) do
          [head * 2 | double(tail)]
        end

        def double([]), do: []
      end
      """

      assert_clean(UnboundedRecursion, code)
    end

    test "allows recursion with depth guard" do
      code = ~S"""
      defmodule MyApp.Walker do
        @max_depth 50

        def walk(node, depth \\ 0)

        def walk(_node, depth) when depth > 50 do
          {:error, :too_deep}
        end

        def walk(node, depth) do
          children = get_children(node)
          [node | Enum.flat_map(children, &walk(&1, depth + 1))]
        end
      end
      """

      assert_clean(UnboundedRecursion, code)
    end

    test "allows tail-recursive functions (even without depth guard)" do
      code = ~S"""
      defmodule MyApp.Counter do
        def count(node, acc \\ 0) do
          children = get_children(node)
          Enum.reduce(children, acc + 1, &count/2)
        end
      end
      """

      # This isn't flagged — Enum.reduce handles the recursion internally
      assert_clean(UnboundedRecursion, code)
    end

    test "allows tree walk with struct pattern match" do
      code = ~S"""
      defmodule MyApp.TreeWalk do
        def flatten(%{children: children, value: value}) do
          [value | Enum.flat_map(children, &flatten/1)]
        end
        def flatten(%{value: value}), do: [value]
      end
      """

      assert_clean(UnboundedRecursion, code)
    end

    test "allows shape walker — tuple destructure + catch-all terminator" do
      # Canonical Elixir AST-walker shape:
      # - one or more clauses pattern-matching on tuple/list/map shapes
      # - a catch-all `def f(_), do: <literal>` terminator
      # The shape grammar IS the depth bound. Body recursion is fine.
      code = ~S"""
      defmodule MyApp.AST do
        def size(nil), do: 0
        def size({_form, _meta, args}), do: 1 + size(args)
        def size({a, b}), do: 1 + size(a) + size(b)
        def size(list) when is_list(list), do: Enum.sum(Enum.map(list, &size/1))
        def size(_), do: 1
      end
      """

      assert_clean(UnboundedRecursion, code)
    end

    test "allows multi-arg shape walker with accumulator terminator" do
      # collect_module_bodies/2-style: catch-all `def f(_, acc), do: acc`
      # qualifies because all args are bare variables / wildcards.
      code = ~S"""
      defmodule MyApp.AST do
        def collect({:defmodule, _, [_, [do: body]]}, acc), do: [body | collect(body, acc)]
        def collect({_form, _meta, args}, acc) when is_list(args), do: Enum.reduce(args, acc, &collect/2)
        def collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
        def collect(_, acc), do: acc
      end
      """

      assert_clean(UnboundedRecursion, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.WalkerTest do
        def walk(node) do
          [node | Enum.flat_map(get_children(node), &walk/1)]
        end
      end
      """

      assert_clean(UnboundedRecursion, code, file: "test/walker_test.exs")
    end
  end
end
