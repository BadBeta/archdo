defmodule Archdo.Rules.Module.PrimitiveObsessionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.PrimitiveObsession

  describe "analyze/3" do
    test "flags function with 3+ typed-concept primitives" do
      code = ~S"""
      defmodule MyApp.Shipping do
        def calculate(email, phone, address, postal_code) do
          :ok
        end
      end
      """

      diags = assert_flagged(PrimitiveObsession, code)
      assert hd(diags).rule_id == "4.12"
      assert hd(diags).message =~ "primitive params"
    end

    test "allows function with non-typed-concept arguments" do
      code = ~S"""
      defmodule MyApp.Math do
        def add(a, b, c) do
          a + b + c
        end
      end
      """

      assert_clean(PrimitiveObsession, code)
    end

    test "allows function with struct parameter" do
      code = ~S"""
      defmodule MyApp.Shipping do
        def calculate(%Address{} = address) do
          :ok
        end
      end
      """

      assert_clean(PrimitiveObsession, code)
    end
  end
end
