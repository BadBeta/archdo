defmodule Archdo.Rules.CompositionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Composition.{ShallowUse, NamespaceDepth}

  describe "10.1 ShallowUse" do
    test "flags module with many non-standard use statements" do
      code = ~S"""
      defmodule MyApp.Worker do
        use MyApp.Schema
        use MyApp.Validations
        use MyApp.Auditable
        def foo, do: :ok
      end
      """

      diags = assert_flagged(ShallowUse, code)
      assert hd(diags).message =~ "non-standard `use`"
    end

    test "allows standard framework uses" do
      code = ~S"""
      defmodule MyApp.Server do
        use GenServer
        use Phoenix.Controller
        def init(_), do: {:ok, %{}}
      end
      """

      assert_clean(ShallowUse, code)
    end
  end

  describe "10.2 NamespaceDepth" do
    test "flags deeply nested module" do
      code = ~S"""
      defmodule MyApp.Accounts.Users.Queries.Admin.Reports do
        def foo, do: :ok
      end
      """

      diags = assert_flagged(NamespaceDepth, code)
      assert hd(diags).message =~ "nesting levels"
    end

    test "allows reasonable depth" do
      code = ~S"""
      defmodule MyApp.Accounts.Users do
        def foo, do: :ok
      end
      """

      assert_clean(NamespaceDepth, code)
    end
  end
end
