defmodule Archdo.Rules.Testing.MissingErrorPathTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.MissingErrorPath

  describe "analyze/3" do
    test "flags test module with 5+ tests but no error-path tests" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        use ExUnit.Case

        test "creates user" do
          assert {:ok, _} = Accounts.create_user(%{name: "Alice"})
        end

        test "lists users" do
          assert [] = Accounts.list_users()
        end

        test "gets user" do
          assert %{} = Accounts.get_user(1)
        end

        test "updates user" do
          assert {:ok, _} = Accounts.update_user(1, %{name: "Bob"})
        end

        test "deletes user" do
          assert :ok = Accounts.delete_user(1)
        end
      end
      """

      diags = assert_flagged(MissingErrorPath, code, file: "test/accounts_test.exs")
      assert hd(diags).rule_id == "7.22"
      assert hd(diags).message =~ "none exercise error"
    end

    test "allows test module with error-path assertions" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        use ExUnit.Case

        test "creates user" do
          assert {:ok, _} = Accounts.create_user(%{name: "Alice"})
        end

        test "rejects invalid user" do
          assert {:error, _} = Accounts.create_user(%{})
        end

        test "lists users" do
          assert [] = Accounts.list_users()
        end

        test "gets user" do
          assert %{} = Accounts.get_user(1)
        end

        test "updates user" do
          assert {:ok, _} = Accounts.update_user(1, %{name: "Bob"})
        end
      end
      """

      assert_clean(MissingErrorPath, code, file: "test/accounts_test.exs")
    end

    test "allows test module with assert_raise" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        use ExUnit.Case

        test "creates user" do
          assert {:ok, _} = Accounts.create_user(%{name: "Alice"})
        end

        test "raises on nil" do
          assert_raise ArgumentError, fn -> Accounts.create_user(nil) end
        end

        test "lists users" do
          assert [] = Accounts.list_users()
        end

        test "gets user" do
          assert %{} = Accounts.get_user(1)
        end

        test "updates user" do
          assert {:ok, _} = Accounts.update_user(1, %{name: "Bob"})
        end
      end
      """

      assert_clean(MissingErrorPath, code, file: "test/accounts_test.exs")
    end

    test "skips test module with fewer than 5 tests" do
      code = ~S"""
      defmodule MyApp.SmallTest do
        use ExUnit.Case

        test "one" do
          assert true
        end

        test "two" do
          assert true
        end
      end
      """

      assert_clean(MissingErrorPath, code, file: "test/small_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create_user(attrs), do: {:ok, attrs}
        def list_users, do: []
        def get_user(id), do: %{id: id}
        def update_user(id, attrs), do: {:ok, Map.put(attrs, :id, id)}
        def delete_user(_id), do: :ok
      end
      """

      assert_clean(MissingErrorPath, code, file: "lib/my_app/accounts.ex")
    end
  end
end
