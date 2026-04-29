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

  test "does not flag Mix tasks calling external services directly (operational layer)" do
    code = ~S"""
    defmodule Mix.Tasks.MyApp.Sync do
      use Mix.Task

      def run(_) do
        Req.get!("https://api.example.com/sync")
      end
    end
    """

    assert_clean(ExternalDepsNoBehaviour, code, file: "lib/mix/tasks/my_app.sync.ex")
  end

  test "does not flag release scripts calling external services" do
    code = ~S"""
    defmodule MyApp.Release do
      def warm do
        Req.get!("https://api.example.com/warm")
      end
    end
    """

    assert_clean(ExternalDepsNoBehaviour, code, file: "lib/my_app/release.ex")
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
