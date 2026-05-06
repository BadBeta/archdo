defmodule Archdo.Rules.Testing.ChangesetErrorsAccessInTestTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.ChangesetErrorsAccessInTest

  describe "analyze/3" do
    test "flags direct .errors field access in a test assertion" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "rejects blank email" do
          changeset = User.changeset(%User{}, %{email: ""})
          refute changeset.valid?
          assert {"can't be blank", _} = changeset.errors[:email]
        end
      end
      """

      diags = assert_flagged(ChangesetErrorsAccessInTest, code, file: "test/user_test.exs")
      assert hd(diags).rule_id == "7.31"
    end

    test "flags Keyword.get(cs.errors, ...) access" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "errors include email" do
          cs = User.changeset(%User{}, %{})
          assert Keyword.get(cs.errors, :email)
        end
      end
      """

      diags = assert_flagged(ChangesetErrorsAccessInTest, code, file: "test/user_test.exs")
      assert hd(diags).rule_id == "7.31"
    end

    test "ignores tests using errors_on/1" do
      code = ~S"""
      defmodule MyApp.UserTest do
        use ExUnit.Case

        test "rejects blank email" do
          changeset = User.changeset(%User{}, %{email: ""})
          assert %{email: ["can't be blank"]} = errors_on(changeset)
        end
      end
      """

      assert_clean(ChangesetErrorsAccessInTest, code, file: "test/user_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.User do
        def report(cs), do: cs.errors
      end
      """

      assert_clean(ChangesetErrorsAccessInTest, code, file: "lib/my_app/user.ex")
    end
  end
end
