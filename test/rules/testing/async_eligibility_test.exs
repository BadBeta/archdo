defmodule Archdo.Rules.Testing.AsyncEligibilityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.AsyncEligibility

  describe "analyze/3" do
    test "flags test file without async: true when eligible" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "creates user" do
          assert {:ok, _} = create()
        end
      end
      """

      diags = assert_flagged(AsyncEligibility, code, file: "test/user_test.exs")
      assert hd(diags).rule_id == "7.4"
    end

    test "allows test file with async: true" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case, async: true

        test "creates user" do
          assert {:ok, _} = create()
        end
      end
      """

      assert_clean(AsyncEligibility, code, file: "test/user_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer
      end
      """

      assert_clean(AsyncEligibility, code, file: "lib/my_app/worker.ex")
    end
  end
end
