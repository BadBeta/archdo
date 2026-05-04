defmodule Archdo.InputGuardTest do
  use ExUnit.Case, async: true

  alias Archdo.InputGuard

  defp ast(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    ast
  end

  describe "collect_clauses/1" do
    test "groups clauses by {name, arity}" do
      tree = ast(~S"""
      defmodule M do
        def foo(x), do: x
        def foo(x, y), do: x + y
        def bar(z), do: z
      end
      """)

      clauses = InputGuard.collect_clauses(tree)
      assert Map.has_key?(clauses, {:foo, 1})
      assert Map.has_key?(clauses, {:foo, 2})
      assert Map.has_key?(clauses, {:bar, 1})
    end

    test "marks guarded clauses with guard?: true" do
      tree = ast(~S"""
      defmodule M do
        def foo(x) when is_integer(x), do: x
      end
      """)

      [clause] = InputGuard.collect_clauses(tree)[{:foo, 1}]
      assert clause.guard? == true
    end

    test "marks plain clauses with guard?: false" do
      tree = ast(~S"""
      defmodule M do
        def foo(x), do: x
      end
      """)

      [clause] = InputGuard.collect_clauses(tree)[{:foo, 1}]
      assert clause.guard? == false
    end

    test "ignores defp" do
      tree = ast(~S"""
      defmodule M do
        defp foo(x), do: x
      end
      """)

      assert InputGuard.collect_clauses(tree) == %{}
    end
  end

  describe "any_unconstrained?/1" do
    test "false when every clause has a guard" do
      tree = ast(~S"""
      defmodule M do
        def f(x) when is_integer(x), do: x
        def f(x) when is_binary(x), do: x
      end
      """)

      clauses = InputGuard.collect_clauses(tree)[{:f, 1}]
      refute InputGuard.any_unconstrained?(clauses)
    end

    test "true when any clause has a bare-variable arg without guard or error fallback" do
      tree = ast(~S"""
      defmodule M do
        def f(x), do: x + 1
      end
      """)

      clauses = InputGuard.collect_clauses(tree)[{:f, 1}]
      assert InputGuard.any_unconstrained?(clauses)
    end

    test "false when an unguarded clause returns {:error, _}" do
      tree = ast(~S"""
      defmodule M do
        def f(x) when is_integer(x), do: {:ok, x}
        def f(_), do: {:error, :bad_input}
      end
      """)

      clauses = InputGuard.collect_clauses(tree)[{:f, 1}]
      refute InputGuard.any_unconstrained?(clauses)
    end

    test "false when args are all specific patterns (no bare vars)" do
      tree = ast(~S"""
      defmodule M do
        def f(:a), do: 1
        def f(:b), do: 2
      end
      """)

      clauses = InputGuard.collect_clauses(tree)[{:f, 1}]
      refute InputGuard.any_unconstrained?(clauses)
    end
  end
end
