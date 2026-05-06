defmodule Archdo.Rules.Module.BangPairInconsistencyTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.BangPairInconsistency

  describe "analyze/3" do
    test "flags `foo!/1` defined without companion `foo/1`" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def fetch_user!(id) do
          {:ok, user} = lookup(id)
          user
        end
      end
      """

      diags =
        assert_flagged(BangPairInconsistency, code, file: "lib/my_app/accounts.ex")

      assert hd(diags).rule_id == "1.35"
    end

    test "ignores when both `foo/1` and `foo!/1` are defined" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def fetch_user(id), do: lookup(id)

        def fetch_user!(id) do
          {:ok, user} = fetch_user(id)
          user
        end
      end
      """

      assert_clean(BangPairInconsistency, code, file: "lib/my_app/accounts.ex")
    end

    test "ignores `foo/0` defined without bang" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def list_users, do: []
      end
      """

      assert_clean(BangPairInconsistency, code, file: "lib/my_app/accounts.ex")
    end

    test "respects arity — flags `foo!/1` even if `foo/2` exists" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def fetch_user(id, opts), do: lookup(id, opts)
        def fetch_user!(id), do: lookup!(id)
      end
      """

      assert_flagged(BangPairInconsistency, code, file: "lib/my_app/accounts.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        def setup_user!(id), do: id
      end
      """

      assert_clean(BangPairInconsistency, code, file: "test/accounts_test.exs")
    end

    test "ignores private bang functions (defp foo!)" do
      code = ~S"""
      defmodule MyApp.Accounts do
        defp normalize!(s), do: String.downcase(s)
      end
      """

      assert_clean(BangPairInconsistency, code, file: "lib/my_app/accounts.ex")
    end
  end
end
