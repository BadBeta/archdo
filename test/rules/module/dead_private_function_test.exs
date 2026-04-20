defmodule Archdo.Rules.Module.DeadPrivateFunctionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.DeadPrivateFunction

  describe "dead private functions" do
    test "flags a private function that is never called" do
      code = ~S"""
      defmodule MyApp.Users do
        def create(attrs) do
          validate(attrs)
        end

        defp validate(attrs), do: attrs

        defp unused_helper(x), do: x * 2
      end
      """

      diagnostics = assert_flagged(DeadPrivateFunction, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.34"
      assert diag.severity == :warning
      assert diag.message =~ "unused_helper/1"
      assert diag.message =~ "never called"
    end

    test "flags multiple dead private functions" do
      code = ~S"""
      defmodule MyApp.Math do
        def add(a, b), do: a + b

        defp dead_one(x), do: x + 1
        defp dead_two(x, y), do: x + y
      end
      """

      diagnostics = assert_flagged(DeadPrivateFunction, code)
      assert length(diagnostics) == 2
      names = Enum.map(diagnostics, & &1.message)
      assert Enum.any?(names, &(&1 =~ "dead_one/1"))
      assert Enum.any?(names, &(&1 =~ "dead_two/2"))
    end

    test "does not flag multi-clause private function where one clause name is called" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          do_parse(input)
        end

        defp do_parse(""), do: :empty
        defp do_parse(str), do: String.trim(str)
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end
  end

  describe "clean code" do
    test "does not flag private functions that are called" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def register(attrs) do
          attrs
          |> build_user()
          |> validate()
        end

        defp build_user(attrs), do: Map.put(attrs, :id, 1)
        defp validate(user), do: {:ok, user}
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.UsersTest do
        defp unused_helper(x), do: x
      end
      """

      assert_clean(DeadPrivateFunction, code, file: "test/users_test.exs")
    end

    test "does not flag dunder functions" do
      code = ~S"""
      defmodule MyApp.CustomMacro do
        def hello, do: :world

        defp __before_compile__(env), do: env
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end

    test "does not flag sigil functions" do
      code = ~S"""
      defmodule MyApp.Sigils do
        def test, do: :ok

        defp sigil_x(string, _opts), do: string
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end
  end

  describe "edge cases" do
    test "handles functions with zero arity" do
      code = ~S"""
      defmodule MyApp.Config do
        def load do
          defaults()
        end

        defp defaults, do: %{timeout: 5000}
        defp unused_defaults, do: %{timeout: 3000}
      end
      """

      diagnostics = assert_flagged(DeadPrivateFunction, code)
      assert [diag] = diagnostics
      assert diag.message =~ "unused_defaults/0"
    end

    test "distinguishes by arity when gap is more than one" do
      code = ~S"""
      defmodule MyApp.Helpers do
        def run do
          helper(1)
        end

        defp helper(x), do: x
        defp helper(x, y, z), do: x + y + z
      end
      """

      diagnostics = assert_flagged(DeadPrivateFunction, code)
      assert [diag] = diagnostics
      assert diag.message =~ "helper/3"
    end
  end
end
