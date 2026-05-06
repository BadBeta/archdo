defmodule Archdo.Rules.Module.BoundaryAtomStringMismatchTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.BoundaryAtomStringMismatch

  test "fires when controller action pattern-matches atom keys against `params` (Phoenix params are string-keyed)" do
    code = ~S"""
    defmodule MyAppWeb.UserController do
      use Phoenix.Controller

      def show(conn, %{id: id}) do
        render(conn, :show, id: id)
      end
    end
    """

    diags =
      assert_flagged(BoundaryAtomStringMismatch, code,
        file: "lib/my_app_web/controllers/user_controller.ex"
      )

    assert hd(diags).rule_id == "6.75"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "string"
  end

  test "does NOT fire when controller uses string keys (correct for Phoenix params)" do
    code = ~S"""
    defmodule MyAppWeb.UserController do
      use Phoenix.Controller

      def show(conn, %{"id" => id}) do
        render(conn, :show, id: id)
      end
    end
    """

    assert_clean(BoundaryAtomStringMismatch, code,
      file: "lib/my_app_web/controllers/user_controller.ex"
    )
  end

  test "does NOT fire on a non-controller / non-LiveView module that uses atom keys (internal data)" do
    code = ~S"""
    defmodule MyApp.Internal do
      def fetch(%{id: id}), do: {:ok, id}
    end
    """

    assert_clean(BoundaryAtomStringMismatch, code, file: "lib/my_app/internal.ex")
  end
end
