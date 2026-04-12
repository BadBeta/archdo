defmodule Archdo.Rules.Module.MissingModuledocTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.MissingModuledoc

  test "flags module without @moduledoc" do
    code = ~S"""
    defmodule MyApp.Accounts do
      def list_users, do: []
    end
    """

    diags = assert_flagged(MissingModuledoc, code)
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "MyApp.Accounts"
    assert hd(diags).message =~ "no @moduledoc"
  end

  test "allows module with @moduledoc" do
    code = ~S"""
    defmodule MyApp.Accounts do
      @moduledoc "Accounts context"
      def list_users, do: []
    end
    """

    assert_clean(MissingModuledoc, code)
  end

  test "allows module with @moduledoc false" do
    code = ~S"""
    defmodule MyApp.Accounts.Impl do
      @moduledoc false
      def list_users, do: []
    end
    """

    assert_clean(MissingModuledoc, code)
  end

  test "ignores test files" do
    code = ~S"""
    defmodule MyApp.AccountsTest do
      def list_users, do: []
    end
    """

    assert_clean(MissingModuledoc, code, file: "test/accounts_test.exs")
  end
end
