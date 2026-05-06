defmodule Archdo.Rules.Module.PhantomTypeOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.PhantomTypeOpportunity

  describe "phantom-type opportunity" do
    test "flags module with defstruct + validate returning {:ok, %__MODULE__{}} + consumer" do
      code = ~S"""
      defmodule MyApp.Email do
        defstruct [:address]

        def validate(input) do
          case String.contains?(input, "@") do
            true -> {:ok, %__MODULE__{address: input}}
            false -> {:error, :invalid}
          end
        end

        def domain(%__MODULE__{address: address}) do
          [_, domain] = String.split(address, "@")
          domain
        end
      end
      """

      [diag] = assert_flagged(PhantomTypeOpportunity, code)
      assert diag.rule_id == "6.103"
      assert diag.severity == :info
      assert diag.message =~ "phantom"
    end

    test "flags module with parse/1 returning {:ok, %__MODULE__{}} and consumer" do
      code = ~S"""
      defmodule MyApp.OAuthToken do
        defstruct [:value, :expires_at]

        def parse(s) do
          {:ok, %__MODULE__{value: s, expires_at: nil}}
        end

        def expired?(%__MODULE__{expires_at: e}), do: e
      end
      """

      [diag] = assert_flagged(PhantomTypeOpportunity, code)
      assert diag.message =~ "phantom"
    end
  end

  describe "clean code" do
    test "does not flag module with defstruct but no validator" do
      code = ~S"""
      defmodule MyApp.User do
        defstruct [:id, :name]

        def display(%__MODULE__{name: n}), do: n
      end
      """

      assert_clean(PhantomTypeOpportunity, code)
    end

    test "does not flag module with validator but no consumer" do
      code = ~S"""
      defmodule MyApp.Email do
        defstruct [:address]

        def validate(input) do
          case String.contains?(input, "@") do
            true -> {:ok, %__MODULE__{address: input}}
            false -> {:error, :invalid}
          end
        end
      end
      """

      assert_clean(PhantomTypeOpportunity, code)
    end

    test "does not flag module without defstruct" do
      code = ~S"""
      defmodule MyApp.Helpers do
        def validate(input), do: {:ok, input}
        def consume(x), do: x
      end
      """

      assert_clean(PhantomTypeOpportunity, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.EmailTest do
        defstruct [:a]

        def validate(x), do: {:ok, %__MODULE__{a: x}}
        def use(%__MODULE__{a: a}), do: a
      end
      """

      assert_clean(PhantomTypeOpportunity, code, file: "test/email_test.exs")
    end
  end
end
