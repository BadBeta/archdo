defmodule Archdo.Rules.Boundary.AtomAtBoundaryTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Boundary.AtomAtBoundary

  describe "analyze/3 — controller files" do
    test "flags String.to_atom in a controller" do
      code = ~S"""
      defmodule MyAppWeb.OrderController do
        use Phoenix.Controller

        def show(conn, %{"sort_by" => sort}) do
          # RULE-EXCEPTION: elixir-string-to-atom-untrusted reason: rule-under-test fixture
          render(conn, :show, sort: String.to_atom(sort))
        end
      end
      """

      diags =
        assert_flagged(AtomAtBoundary, code,
          file: "lib/my_app_web/controllers/order_controller.ex"
        )

      diag = hd(diags)
      assert diag.severity == :error
      assert diag.title =~ "boundary"
    end

    test "flags :erlang.binary_to_atom/1 in a controller" do
      code = ~S"""
      defmodule MyAppWeb.OrderController do
        use Phoenix.Controller

        def show(conn, %{"key" => key}) do
          render(conn, :show, k: :erlang.binary_to_atom(key))
        end
      end
      """

      assert_flagged(AtomAtBoundary, code, file: "lib/my_app_web/controllers/order_controller.ex")
    end

    test "flags :erlang.list_to_atom/1 in a controller" do
      code = ~S"""
      defmodule MyAppWeb.OrderController do
        use Phoenix.Controller

        def show(conn, %{"chars" => chars}) do
          render(conn, :show, k: :erlang.list_to_atom(chars))
        end
      end
      """

      assert_flagged(AtomAtBoundary, code, file: "lib/my_app_web/controllers/order_controller.ex")
    end

    test "flags atom interpolation in a controller" do
      code = ~S"""
      defmodule MyAppWeb.OrderController do
        use Phoenix.Controller

        def show(conn, %{"id" => id}) do
          name = :"order_#{id}"
          render(conn, :show, name: name)
        end
      end
      """

      assert_flagged(AtomAtBoundary, code, file: "lib/my_app_web/controllers/order_controller.ex")
    end
  end

  describe "analyze/3 — channel files" do
    test "flags String.to_atom in a Phoenix channel" do
      code = ~S"""
      defmodule MyAppWeb.RoomChannel do
        use Phoenix.Channel

        def handle_in("event", %{"type" => type}, socket) do
          # RULE-EXCEPTION: elixir-string-to-atom-untrusted reason: rule-under-test fixture
          dispatch(String.to_atom(type), socket)
          {:reply, :ok, socket}
        end
      end
      """

      assert_flagged(AtomAtBoundary, code, file: "lib/my_app_web/channels/room_channel.ex")
    end
  end

  describe "analyze/3 — Oban worker files" do
    test "flags String.to_atom in an Oban worker" do
      code = ~S"""
      defmodule MyApp.Workers.Sync do
        use Oban.Worker

        def perform(%{args: %{"action" => action}}) do
          # RULE-EXCEPTION: elixir-string-to-atom-untrusted reason: rule-under-test fixture
          do_action(String.to_atom(action))
        end
      end
      """

      assert_flagged(AtomAtBoundary, code, file: "lib/my_app/workers/sync.ex")
    end
  end

  describe "analyze/3 — Plug files" do
    test "flags String.to_atom in a custom Plug" do
      code = ~S"""
      defmodule MyAppWeb.Plugs.AuthPlug do
        @behaviour Plug

        def init(opts), do: opts

        def call(conn, _opts) do
          # RULE-EXCEPTION: elixir-string-to-atom-untrusted reason: rule-under-test fixture
          role = String.to_atom(conn.params["role"])
          assign(conn, :role, role)
        end
      end
      """

      assert_flagged(AtomAtBoundary, code, file: "lib/my_app_web/plugs/auth_plug.ex")
    end
  end

  describe "analyze/3 — non-boundary files" do
    test "does not flag String.to_atom in a domain context module" do
      code = ~S"""
      defmodule MyApp.Accounts do
        # RULE-EXCEPTION: elixir-string-to-atom-untrusted reason: rule-under-test fixture
        def parse_role(role), do: String.to_atom(role)
      end
      """

      assert_clean(AtomAtBoundary, code, file: "lib/my_app/accounts.ex")
    end

    test "skips Mix tasks (operational layer)" do
      code = ~S"""
      defmodule Mix.Tasks.MyApp.Sync do
        use Mix.Task
        # RULE-EXCEPTION: elixir-string-to-atom-untrusted reason: rule-under-test fixture
        def run([flag | _]), do: String.to_atom(flag)
      end
      """

      assert_clean(AtomAtBoundary, code, file: "lib/mix/tasks/my_app.sync.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyAppWeb.OrderControllerTest do
        # RULE-EXCEPTION: elixir-string-to-atom-untrusted reason: rule-under-test fixture
        def helper(input), do: String.to_atom(input)
      end
      """

      assert analyze(AtomAtBoundary, code,
               file: "test/my_app_web/controllers/order_controller_test.exs"
             ) == []
    end
  end

  describe "analyze/3 — safe variants in boundary files" do
    test "allows String.to_existing_atom in a controller" do
      code = ~S"""
      defmodule MyAppWeb.OrderController do
        use Phoenix.Controller

        def show(conn, %{"sort_by" => sort}) do
          render(conn, :show, sort: String.to_existing_atom(sort))
        end
      end
      """

      assert_clean(AtomAtBoundary, code, file: "lib/my_app_web/controllers/order_controller.ex")
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert AtomAtBoundary.id() == "1.20"
    end

    test "description mentions atom and boundary" do
      desc = AtomAtBoundary.description()
      assert desc =~ "atom" or desc =~ "Atom"
      assert desc =~ "boundary"
    end
  end
end
