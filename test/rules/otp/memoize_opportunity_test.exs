defmodule Archdo.Rules.OTP.MemoizeOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.MemoizeOpportunity

  describe "memoize opportunity" do
    test "flags Regex.compile! on a string literal inside a fn body" do
      code = ~S"""
      defmodule MyApp.Validator do
        @moduledoc "Building block: input validation."

        def valid?(input) do
          regex = Regex.compile!("^[a-z]+$")
          Regex.match?(regex, input)
        end
      end
      """

      [diag] = assert_flagged(MemoizeOpportunity, code)
      assert diag.rule_id == "5.75"
      assert diag.severity == :info
      assert diag.message =~ "Regex.compile"
    end

    test "flags Jason.decode! on a literal binary inside a fn body" do
      code = ~S"""
      defmodule MyApp.Settings do
        @moduledoc "Building block: settings access."

        def defaults do
          Jason.decode!(~s({"foo": 1, "bar": 2}))
        end
      end
      """

      [diag] = assert_flagged(MemoizeOpportunity, code)
      assert diag.message =~ "Jason"
    end

    test "flags :crypto.hash on a literal inside a fn body" do
      code = ~S"""
      defmodule MyApp.Token do
        @moduledoc "Building block: token signing."

        def issuer_hash do
          :crypto.hash(:sha256, "myapp.example.com")
        end
      end
      """

      [diag] = assert_flagged(MemoizeOpportunity, code)
      assert diag.message =~ "crypto"
    end
  end

  describe "clean code" do
    test "does not flag module-level Regex.compile! attribute" do
      code = ~S"""
      defmodule MyApp.Validator do
        @moduledoc "Building block: input validation."
        @rx Regex.compile!("^[a-z]+$")

        def valid?(input), do: Regex.match?(@rx, input)
      end
      """

      assert_clean(MemoizeOpportunity, code)
    end

    test "does not flag Regex.compile! on a runtime value" do
      code = ~S"""
      defmodule MyApp.DynamicMatcher do
        @moduledoc "Building block: dynamic matchers."

        def matches?(pattern, input) do
          regex = Regex.compile!(pattern)
          Regex.match?(regex, input)
        end
      end
      """

      assert_clean(MemoizeOpportunity, code)
    end

    test "does not flag in non-building-block module" do
      code = ~S"""
      defmodule MyApp.OneOff do
        def run do
          regex = Regex.compile!("^x$")
          regex
        end
      end
      """

      assert_clean(MemoizeOpportunity, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.ValidatorTest do
        @moduledoc "Building block tests."

        def helper(input) do
          regex = Regex.compile!("^x$")
          Regex.match?(regex, input)
        end
      end
      """

      assert_clean(MemoizeOpportunity, code, file: "test/validator_test.exs")
    end
  end
end
