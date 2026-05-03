defmodule Archdo.Rules.Testing.MockingOwnModulesTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.MockingOwnModules

  describe "analyze/3" do
    test "flags Mox.defmock targeting internal module" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case

        Mox.defmock(MockAccounts, for: MyApp.Accounts)

        test "ok", do: assert true
      end
      """

      diags = assert_flagged(MockingOwnModules, code, file: "test/service_test.exs")
      assert hd(diags).rule_id == "7.15"
      assert hd(diags).message =~ "MyApp.Accounts"
    end

    test "allows mocking external/boundary modules" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case

        Mox.defmock(MockHTTP, for: MyApp.HTTPClient)

        test "ok", do: assert true
      end
      """

      assert_clean(MockingOwnModules, code, file: "test/service_test.exs")
    end

    test "ignores non-test files" do
      code = ~S"""
      defmodule MyApp.Service do
        def run, do: :ok
      end
      """

      assert_clean(MockingOwnModules, code, file: "lib/my_app/service.ex")
    end

    # Each boundary marker (adapter/client/mailer/infrastructure/http/gateway/boundary)
    # exempts the target module. Pin each one so a refactor that
    # changes the marker list breaks loudly.
    for {marker, sample} <- [
          {"adapter", "MyApp.PaymentAdapter"},
          {"client", "MyApp.StripeClient"},
          {"mailer", "MyApp.WelcomeMailer"},
          {"infrastructure", "MyApp.Infrastructure.Db"},
          {"http", "MyApp.HttpFetcher"},
          {"gateway", "MyApp.PaymentGateway"},
          {"boundary", "MyApp.AccountsBoundary"}
        ] do
      test "boundary marker '#{marker}' exempts the target (#{sample})" do
        code = """
        defmodule MyApp.ServiceTest do
          use ExUnit.Case

          Mox.defmock(MockX, for: #{unquote(sample)})

          test "ok", do: assert true
        end
        """

        assert_clean(MockingOwnModules, code, file: "test/service_test.exs")
      end
    end
  end
end
