defmodule Archdo.Rules.Composition.ShallowUseTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Composition.ShallowUse

  describe "analyze/3" do
    test "flags module with many non-standard use statements" do
      code = ~S"""
      defmodule MyApp.Web.Dashboard do
        use MyApp.Schema
        use MyApp.Pagination
        use MyApp.Filterable

        def list, do: []
      end
      """

      diags = assert_flagged(ShallowUse, code)
      assert hd(diags).rule_id == "10.1"
    end

    test "allows standard framework uses" do
      code = ~S"""
      defmodule MyApp.Web.PageController do
        use Phoenix.Controller
        use Phoenix.LiveView

        def index(conn, _params), do: conn
      end
      """

      assert_clean(ShallowUse, code)
    end

    test "allows up to 2 non-standard uses" do
      code = ~S"""
      defmodule MyApp.Workers.Importer do
        use GenServer
        use MyApp.Schema
        use MyApp.Validatable

        def init(_), do: {:ok, %{}}
      end
      """

      assert_clean(ShallowUse, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.BigTest do
        use ExUnit.Case
        use MyApp.DataFactory
        use MyApp.AssertHelper
        use MyApp.FakeServer

        test "ok", do: assert true
      end
      """

      assert_clean(ShallowUse, code, file: "test/big_test.exs")
    end
  end
end
