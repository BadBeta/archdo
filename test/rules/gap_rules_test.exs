defmodule Archdo.Rules.GapRulesTest do
  use Archdo.RuleCase

  # OTP Rules

  describe "5.37 MissingHandleInfo" do
    alias Archdo.Rules.OTP.MissingHandleInfo

    test "flags GenServer without handle_info" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer
        def init(state), do: {:ok, state}
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """

      diags = assert_flagged(MissingHandleInfo, code)
      assert hd(diags).rule_id == "5.37"
    end

    test "allows GenServer with handle_info" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer
        def init(state), do: {:ok, state}
        def handle_info(_msg, state), do: {:noreply, state}
      end
      """

      assert_clean(MissingHandleInfo, code)
    end
  end

  describe "5.38 CallSelfDeadlock" do
    alias Archdo.Rules.OTP.CallSelfDeadlock

    test "flags GenServer.call(__MODULE__) in callback" do
      code = ~S"""
      defmodule MyApp.Cache do
        use GenServer
        def init(state), do: {:ok, state}
        def handle_call(:refresh, _from, state) do
          data = GenServer.call(__MODULE__, :get_all)
          {:reply, data, state}
        end
      end
      """

      diags = assert_flagged(CallSelfDeadlock, code)
      assert hd(diags).rule_id == "5.38"
    end

    test "allows GenServer.call to other process" do
      code = ~S"""
      defmodule MyApp.Proxy do
        use GenServer
        def init(state), do: {:ok, state}
        def handle_call(:fetch, _from, state) do
          data = GenServer.call(MyApp.Backend, :get)
          {:reply, data, state}
        end
      end
      """

      assert_clean(CallSelfDeadlock, code)
    end
  end

  describe "5.39 BrutalKill" do
    alias Archdo.Rules.OTP.BrutalKill

    test "flags Process.exit(pid, :kill)" do
      code = ~S"""
      defmodule MyApp.Terminator do
        def stop(pid) do
          Process.exit(pid, :kill)
        end
      end
      """

      diags = assert_flagged(BrutalKill, code)
      assert hd(diags).rule_id == "5.39"
    end

    test "allows Process.exit(pid, :shutdown)" do
      code = ~S"""
      defmodule MyApp.Terminator do
        def stop(pid) do
          Process.exit(pid, :shutdown)
        end
      end
      """

      assert_clean(BrutalKill, code)
    end
  end

  describe "5.40 EtsOwnershipLeak" do
    alias Archdo.Rules.OTP.EtsOwnershipLeak

    test "flags GenServer creating ETS without terminate" do
      code = ~S"""
      defmodule MyApp.Cache do
        use GenServer
        def init(_) do
          table = :ets.new(:cache, [:named_table])
          {:ok, %{table: table}}
        end
        def handle_call(:get, _from, state), do: {:reply, :ok, state}
      end
      """

      diags = assert_flagged(EtsOwnershipLeak, code)
      assert hd(diags).rule_id == "5.40"
    end

    test "allows GenServer with ETS and terminate" do
      code = ~S"""
      defmodule MyApp.Cache do
        use GenServer
        def init(_) do
          table = :ets.new(:cache, [:named_table])
          {:ok, %{table: table}}
        end
        def terminate(_reason, %{table: table}) do
          :ets.delete(table)
        end
      end
      """

      assert_clean(EtsOwnershipLeak, code)
    end
  end

  describe "5.41 HardcodedCallTimeout" do
    alias Archdo.Rules.OTP.HardcodedCallTimeout

    test "flags GenServer.call with hardcoded timeout" do
      code = ~S"""
      defmodule MyApp.Client do
        def fetch(server) do
          GenServer.call(server, :fetch, 15000)
        end
      end
      """

      diags = assert_flagged(HardcodedCallTimeout, code)
      assert hd(diags).rule_id == "5.41"
    end

    test "allows GenServer.call without explicit timeout" do
      code = ~S"""
      defmodule MyApp.Client do
        def fetch(server) do
          GenServer.call(server, :fetch)
        end
      end
      """

      assert_clean(HardcodedCallTimeout, code)
    end
  end

  # Architecture Rules

  describe "6.17 NestingDepth" do
    alias Archdo.Rules.Module.NestingDepth

    test "flags deeply nested control flow" do
      code = ~S"""
      defmodule MyApp.Complex do
        def process(data) do
          case validate(data) do
            :ok ->
              with {:ok, x} <- step1(data) do
                case transform(x) do
                  {:ok, y} ->
                    if y.valid? do
                      case finalize(y) do
                        {:ok, z} -> z
                        _ -> nil
                      end
                    end
                  _ -> nil
                end
              end
            _ -> nil
          end
        end
      end
      """

      diags = assert_flagged(NestingDepth, code)
      assert hd(diags).rule_id == "6.17"
    end

    test "allows flat control flow" do
      code = ~S"""
      defmodule MyApp.Simple do
        def process(data) do
          with :ok <- validate(data),
               {:ok, x} <- step1(data),
               {:ok, y} <- transform(x) do
            finalize(y)
          end
        end
      end
      """

      assert_clean(NestingDepth, code)
    end
  end

  describe "1.15 LogicInController" do
    alias Archdo.Rules.Boundary.LogicInController

    test "flags large controller action" do
      # Generate a large action body
      lines = Enum.map_join(1..50, "\n", fn i -> "    var_#{i} = process(#{i})" end)

      code = """
      defmodule MyAppWeb.UserController do
        def create(conn, params) do
      #{lines}
          json(conn, %{ok: true})
        end
      end
      """

      diags =
        assert_flagged(LogicInController, code,
          file: "lib/my_app_web/controllers/user_controller.ex"
        )

      assert hd(diags).rule_id == "1.15"
    end

    test "allows thin controller action" do
      code = ~S"""
      defmodule MyAppWeb.UserController do
        def create(conn, params) do
          case MyApp.Accounts.create_user(params) do
            {:ok, user} -> json(conn, user)
            {:error, changeset} -> json(conn, changeset)
          end
        end
      end
      """

      assert_clean(LogicInController, code,
        file: "lib/my_app_web/controllers/user_controller.ex"
      )
    end
  end

  # Testing Rules

  describe "7.18 WeakAssertion" do
    alias Archdo.Rules.Testing.WeakAssertion

    test "flags assert function() without pattern" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        use ExUnit.Case

        test "creates user" do
          assert MyApp.Accounts.create_user(%{name: "test"})
        end
      end
      """

      diags = assert_flagged(WeakAssertion, code, file: "test/accounts_test.exs")
      assert hd(diags).rule_id == "7.18"
    end

    test "allows assert with pattern match" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        use ExUnit.Case

        test "creates user" do
          assert {:ok, _user} = MyApp.Accounts.create_user(%{name: "test"})
        end
      end
      """

      assert_clean(WeakAssertion, code, file: "test/accounts_test.exs")
    end

    test "allows assert with predicate function" do
      code = ~S"""
      defmodule MyApp.ListTest do
        use ExUnit.Case

        test "has items" do
          assert Enum.any?(list, &valid?/1)
        end
      end
      """

      assert_clean(WeakAssertion, code, file: "test/list_test.exs")
    end
  end

  describe "7.19 MissingTestCleanup" do
    alias Archdo.Rules.Testing.MissingTestCleanup

    test "flags test starting process without cleanup" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "worker runs" do
          {:ok, pid} = GenServer.start_link(MyApp.Worker, [])
          assert GenServer.call(pid, :status) == :ok
        end
      end
      """

      diags = assert_flagged(MissingTestCleanup, code, file: "test/worker_test.exs")
      assert hd(diags).rule_id == "7.19"
    end

    test "allows test using start_supervised!" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "worker runs" do
          pid = start_supervised!({MyApp.Worker, []})
          assert GenServer.call(pid, :status) == :ok
        end
      end
      """

      assert_clean(MissingTestCleanup, code, file: "test/worker_test.exs")
    end
  end

  # Phoenix/LiveView Rules

  describe "1.16 LargeLiveviewAssigns" do
    alias Archdo.Rules.Boundary.LargeLiveviewAssigns

    test "flags LiveView with many assigns" do
      assign_lines =
        Enum.map_join(1..20, "\n", fn i ->
          "    |> assign(:field_#{i}, nil)"
        end)

      code = """
      defmodule MyAppWeb.DashboardLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          socket = socket
      #{assign_lines}
          {:ok, socket}
        end
      end
      """

      diags = assert_flagged(LargeLiveviewAssigns, code, file: "lib/my_app_web/live/dashboard_live.ex")
      assert hd(diags).rule_id == "1.16"
    end

    test "allows LiveView with few assigns" do
      code = ~S"""
      defmodule MyAppWeb.PageLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          {:ok, assign(socket, page: 1, items: [])}
        end
      end
      """

      assert_clean(LargeLiveviewAssigns, code, file: "lib/my_app_web/live/page_live.ex")
    end
  end

  describe "1.17 PubsubWithoutHandler" do
    alias Archdo.Rules.Boundary.PubsubWithoutHandler

    test "flags LiveView subscribing without handle_info" do
      code = ~S"""
      defmodule MyAppWeb.FeedLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          MyAppWeb.Endpoint.subscribe("posts")
          {:ok, socket}
        end
      end
      """

      diags =
        assert_flagged(PubsubWithoutHandler, code,
          file: "lib/my_app_web/live/feed_live.ex"
        )

      assert hd(diags).rule_id == "1.17"
    end

    test "allows LiveView with subscribe and handle_info" do
      code = ~S"""
      defmodule MyAppWeb.FeedLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          MyAppWeb.Endpoint.subscribe("posts")
          {:ok, socket}
        end

        def handle_info(%{event: "new_post"}, socket) do
          {:noreply, socket}
        end
      end
      """

      assert_clean(PubsubWithoutHandler, code,
        file: "lib/my_app_web/live/feed_live.ex"
      )
    end
  end

  # Error Handling

  describe "6.18 ExceptionLaundering" do
    alias Archdo.Rules.Module.ExceptionLaundering

    test "flags rescue catching one exception and raising different" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          do_parse(input)
        rescue
          e in Jason.DecodeError ->
            raise ArgumentError, "bad input: #{e.message}"
        end
      end
      """

      diags = assert_flagged(ExceptionLaundering, code)
      assert hd(diags).rule_id == "6.18"
    end

    test "allows rescue with reraise" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          do_parse(input)
        rescue
          e in Jason.DecodeError ->
            reraise %MyApp.ParseError{message: e.message}, __STACKTRACE__
        end
      end
      """

      assert_clean(ExceptionLaundering, code)
    end
  end
end
