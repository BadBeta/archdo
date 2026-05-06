defmodule Archdo.Rules.Testing.StubWithOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.StubWithOpportunity

  describe "analyze/3" do
    test "flags 3+ stub/3 calls for the same mock module" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case
        import Mox

        setup do
          stub(MockClient, :fetch, fn _ -> {:ok, %{}} end)
          stub(MockClient, :update, fn _, _ -> :ok end)
          stub(MockClient, :delete, fn _ -> :ok end)
          :ok
        end
      end
      """

      diags = assert_flagged(StubWithOpportunity, code, file: "test/service_test.exs")
      assert hd(diags).rule_id == "7.33"
    end

    test "ignores 2 stubs for the same mock" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case
        import Mox

        setup do
          stub(MockClient, :fetch, fn _ -> {:ok, %{}} end)
          stub(MockClient, :update, fn _, _ -> :ok end)
          :ok
        end
      end
      """

      assert_clean(StubWithOpportunity, code, file: "test/service_test.exs")
    end

    test "ignores 3 stubs across different mocks" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case
        import Mox

        setup do
          stub(MockA, :fetch, fn _ -> :ok end)
          stub(MockB, :fetch, fn _ -> :ok end)
          stub(MockC, :fetch, fn _ -> :ok end)
          :ok
        end
      end
      """

      assert_clean(StubWithOpportunity, code, file: "test/service_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Helper do
        def configure do
          stub(MockClient, :fetch, fn _ -> :ok end)
          stub(MockClient, :update, fn _, _ -> :ok end)
          stub(MockClient, :delete, fn _ -> :ok end)
        end
      end
      """

      assert_clean(StubWithOpportunity, code, file: "lib/my_app/helper.ex")
    end
  end
end
