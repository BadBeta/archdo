defmodule Archdo.Rules.CE.CatchAllRescueTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.CatchAllRescue

  test "fires on bare wildcard rescue" do
    code = ~S"""
    defmodule MyApp.Risky do
      def go do
        do_work()
      rescue
        _ -> :error
      end
    end
    """

    diags = assert_flagged(CatchAllRescue, code)
    assert hd(diags).rule_id == "CE-49"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "matches anything"
  end

  test "fires on unfiltered single-variable rescue (`rescue _e`)" do
    code = ~S"""
    defmodule MyApp.Risky do
      def go do
        do_work()
      rescue
        _e -> log_and_return(:error)
      end
    end
    """

    assert [_ | _] = assert_flagged(CatchAllRescue, code)
  end

  test "does NOT fire on rescue with explicit exception type filter" do
    code = ~S"""
    defmodule MyApp.Reader do
      def fetch(path) do
        File.read!(path)
      rescue
        e in File.Error -> {:error, e.reason}
      end
    end
    """

    assert_clean(CatchAllRescue, code)
  end

  test "does NOT fire when @archdo_boundary_rescue marker is present" do
    code = ~S"""
    defmodule MyAppWeb.ErrorRenderer do
      @archdo_boundary_rescue "Plug error renderer — last-line catch is the contract"
      def render_500(conn) do
        do_render(conn)
      rescue
        _ -> conn |> send_resp(500, "boom") |> halt()
      end
    end
    """

    assert_clean(CatchAllRescue, code)
  end
end
