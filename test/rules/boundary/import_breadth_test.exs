defmodule Archdo.Rules.Boundary.ImportBreadthTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Boundary.ImportBreadth

  test "flags import without :only" do
    code = ~S"""
    defmodule MyApp.Accounts do
      import MyApp.Helpers

      def foo, do: helper_fn()
    end
    """

    diags = assert_flagged(ImportBreadth, code)
    diag = hd(diags)
    assert diag.severity == :warning
    assert diag.rule_id == "4.5"
    assert diag.title == "Broad import without :only clause"
    assert diag.context.import == "MyApp.Helpers"
  end

  test "allows import with :only" do
    code = ~S"""
    defmodule MyApp.Accounts do
      import MyApp.Helpers, only: [helper_fn: 0]

      def foo, do: helper_fn()
    end
    """

    assert_clean(ImportBreadth, code)
  end

  test "tolerates import Ecto.Query" do
    code = ~S"""
    defmodule MyApp.Accounts do
      import Ecto.Query

      def list, do: from(u in "users")
    end
    """

    assert_clean(ImportBreadth, code)
  end

  test "tolerates import Ecto.Changeset" do
    code = ~S"""
    defmodule MyApp.Accounts.User do
      import Ecto.Changeset

      def changeset(user, attrs), do: cast(user, attrs, [])
    end
    """

    assert_clean(ImportBreadth, code)
  end

  test "ignores test files" do
    code = ~S"""
    defmodule MyApp.AccountsTest do
      import MyApp.TestHelpers
      def foo, do: create_user()
    end
    """

    assert_clean(ImportBreadth, code, file: "test/accounts_test.exs")
  end

  test "ignores Mix tasks (operational layer)" do
    code = ~S"""
    defmodule Mix.Tasks.MyApp.Sync do
      use Mix.Task
      import Ecto.Query
      def run(_), do: :ok
    end
    """

    assert_clean(ImportBreadth, code, file: "lib/mix/tasks/my_app.sync.ex")
  end
end
