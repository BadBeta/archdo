defmodule Archdo.Rules.Testing.OverMockingTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.OverMocking

  describe "analyze/3" do
    test "flags test with 4+ expect calls" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case

        test "does everything" do
          expect(MockA, :call, fn -> :ok end)
          expect(MockB, :call, fn -> :ok end)
          expect(MockC, :call, fn -> :ok end)
          expect(MockD, :call, fn -> :ok end)
          assert Service.run() == :ok
        end
      end
      """

      diags = assert_flagged(OverMocking, code, file: "test/service_test.exs")
      assert hd(diags).rule_id == "7.23"
      assert hd(diags).title == "Over-mocking in test"
    end

    test "flags test with 3+ stub calls" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case

        test "stubs everything" do
          stub(MockA, :call, fn -> :ok end)
          stub(MockB, :call, fn -> :ok end)
          stub(MockC, :call, fn -> :ok end)
          assert Service.run() == :ok
        end
      end
      """

      diags = assert_flagged(OverMocking, code, file: "test/service_test.exs")
      assert hd(diags).title == "Excessive stubbing in test"
    end

    test "allows test with few expect calls" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        use ExUnit.Case

        test "calls collaborator" do
          expect(MockA, :call, fn -> :ok end)
          expect(MockB, :call, fn -> :ok end)
          assert Service.run() == :ok
        end
      end
      """

      assert_clean(OverMocking, code, file: "test/service_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.TestHelper do
        def setup_mocks do
          expect(MockA, :call, fn -> :ok end)
          expect(MockB, :call, fn -> :ok end)
          expect(MockC, :call, fn -> :ok end)
          expect(MockD, :call, fn -> :ok end)
        end
      end
      """

      assert_clean(OverMocking, code, file: "lib/my_app/test_helper.ex")
    end
  end
end
