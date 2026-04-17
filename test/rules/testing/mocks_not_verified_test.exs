defmodule Archdo.Rules.Testing.MocksNotVerifiedTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.MocksNotVerified

  describe "analyze/3" do
    test "flags test using Mox.expect without verify_on_exit" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case

        test "calls the client" do
          Mox.expect(MockClient, :fetch, fn _url -> {:ok, "data"} end)
          assert MyApp.Service.run() == {:ok, "data"}
        end
      end
      """

      diags = assert_flagged(MocksNotVerified, code, file: "test/service_test.exs")
      assert hd(diags).rule_id == "7.13"
    end

    test "allows test with verify_on_exit" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case
        import Mox

        setup do
          verify_on_exit!()
          :ok
        end

        test "calls the client" do
          Mox.expect(MockClient, :fetch, fn _url -> {:ok, "data"} end)
          assert MyApp.Service.run() == {:ok, "data"}
        end
      end
      """

      assert_clean(MocksNotVerified, code, file: "test/service_test.exs")
    end

    test "ignores non-test files" do
      code = ~S"""
      defmodule MyApp.Service do
        def run, do: :ok
      end
      """

      assert_clean(MocksNotVerified, code, file: "lib/my_app/service.ex")
    end
  end
end
