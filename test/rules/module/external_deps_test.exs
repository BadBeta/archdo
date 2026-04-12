defmodule Archdo.Rules.Module.ExternalDepsNoBehaviourTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ExternalDepsNoBehaviour

  test "flags direct HTTP client call in domain module" do
    code = ~S"""
    defmodule MyApp.Accounts do
      def verify_email(email) do
        Req.get!("https://api.verify.com/#{email}")
      end
    end
    """

    diags = assert_flagged(ExternalDepsNoBehaviour, code)
    assert hd(diags).message =~ "Req"
    assert hd(diags).message =~ "behaviour"
  end

  test "allows calls in adapter modules" do
    code = ~S"""
    defmodule MyApp.Adapters.EmailVerifier do
      def verify(email) do
        Req.get!("https://api.verify.com/#{email}")
      end
    end
    """

    assert_clean(ExternalDepsNoBehaviour, code, file: "lib/my_app/adapters/email_verifier.ex")
  end

  test "ignores test files" do
    code = ~S"""
    defmodule MyApp.AccountsTest do
      def test_verify do
        Req.get!("https://api.verify.com/test")
      end
    end
    """

    assert_clean(ExternalDepsNoBehaviour, code, file: "test/accounts_test.exs")
  end
end
