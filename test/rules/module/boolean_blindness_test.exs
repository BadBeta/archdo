defmodule Archdo.Rules.Module.BooleanBlindnessTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.BooleanBlindness

  describe "analyze/3" do
    test "flags validate function returning bare true/false" do
      code = ~S"""
      defmodule MyApp.Validator do
        def validate(data) do
          case data.valid do
            true -> true
            false -> false
          end
        end
      end
      """

      diags = assert_flagged(BooleanBlindness, code)
      assert length(diags) == 1
      assert hd(diags).rule_id == "6.45"
      assert hd(diags).severity == :info
    end

    test "flags authorize function returning bare true/false" do
      code = ~S"""
      defmodule MyApp.Auth do
        def authorize(user, action) do
          if user.admin do
            true
          else
            false
          end
        end
      end
      """

      diags = assert_flagged(BooleanBlindness, code)
      assert hd(diags).rule_id == "6.45"
    end

    test "allows predicate functions ending with ?" do
      code = ~S"""
      defmodule MyApp.Validator do
        def valid?(data) do
          case data.status do
            :active -> true
            _ -> false
          end
        end
      end
      """

      assert_clean(BooleanBlindness, code)
    end

    test "allows functions returning ok/error tuples" do
      code = ~S"""
      defmodule MyApp.Validator do
        def validate(data) do
          case data.valid do
            true -> {:ok, data}
            false -> {:error, :invalid}
          end
        end
      end
      """

      assert_clean(BooleanBlindness, code)
    end

    test "allows functions with non-failable names" do
      code = ~S"""
      defmodule MyApp.Processor do
        def process(data) do
          if data do
            true
          else
            false
          end
        end
      end
      """

      assert_clean(BooleanBlindness, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.ValidatorTest do
        def validate(data) do
          if data do
            true
          else
            false
          end
        end
      end
      """

      assert_clean(BooleanBlindness, code, file: "test/my_app/validator_test.exs")
    end
  end
end
