defmodule Archdo.Rules.Testing.MoxStubInTestBodyTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.MoxStubInTestBody

  describe "analyze/3" do
    test "flags stub in test body when verify_on_exit! is configured" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case
        import Mox

        setup :verify_on_exit!

        test "calls fetch" do
          stub(MockClient, :fetch, fn _ -> {:ok, %{}} end)
          assert {:ok, _} = MyApp.Service.run("x")
        end
      end
      """

      diags = assert_flagged(MoxStubInTestBody, code, file: "test/service_test.exs")
      assert hd(diags).rule_id == "7.30"
    end

    test "ignores stub in setup block" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case
        import Mox

        setup :verify_on_exit!

        setup do
          stub(MockClient, :fetch, fn _ -> {:ok, %{}} end)
          :ok
        end

        test "happy path" do
          assert {:ok, _} = MyApp.Service.run("x")
        end
      end
      """

      assert_clean(MoxStubInTestBody, code, file: "test/service_test.exs")
    end

    test "ignores stub when expect is also present in same test (mixed setup)" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case
        import Mox

        setup :verify_on_exit!

        test "calls fetch and logs" do
          stub(MockLogger, :info, fn _ -> :ok end)
          expect(MockClient, :fetch, fn _ -> {:ok, %{}} end)
          assert {:ok, _} = MyApp.Service.run("x")
        end
      end
      """

      assert_clean(MoxStubInTestBody, code, file: "test/service_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Helper do
        def configure do
          stub(MockClient, :fetch, fn _ -> {:ok, %{}} end)
        end
      end
      """

      assert_clean(MoxStubInTestBody, code, file: "lib/my_app/helper.ex")
    end
  end
end
