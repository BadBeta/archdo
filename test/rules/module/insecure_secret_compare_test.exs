defmodule Archdo.Rules.Module.InsecureSecretCompareTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.InsecureSecretCompare

  test "fires on `==` comparison where one side has secret-suggesting name (token)" do
    code = ~S"""
    defmodule MyApp.Auth do
      def valid?(submitted_token, expected_token) do
        submitted_token == expected_token
      end
    end
    """

    diags = assert_flagged(InsecureSecretCompare, code)
    assert hd(diags).rule_id == "6.79"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "secure_compare"
  end

  test "does NOT fire on Plug.Crypto.secure_compare/2 (already correct)" do
    code = ~S"""
    defmodule MyApp.Auth do
      def valid?(a, b), do: Plug.Crypto.secure_compare(a, b)
    end
    """

    assert_clean(InsecureSecretCompare, code)
  end

  test "does NOT fire on `==` comparison of non-secret variables" do
    code = ~S"""
    defmodule MyApp.Math do
      def equal?(x, y), do: x == y
    end
    """

    assert_clean(InsecureSecretCompare, code)
  end
end
