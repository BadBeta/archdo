defmodule Archdo.Rules.CE.OpaqueProcessStateTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.OpaqueProcessState

  describe "CE-29 — long-running stateful process without inspection hook" do
    test "fires on `use GenServer` without format_status/1" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def init(opts), do: {:ok, opts}
        def handle_call(:ping, _from, state), do: {:reply, :pong, state}
      end
      """

      diags = assert_flagged(OpaqueProcessState, code)
      assert hd(diags).rule_id == "CE-29"
      assert hd(diags).message =~ "MyApp.Worker"
    end

    test "fires on `use Agent` without format_status/1" do
      code = ~S"""
      defmodule MyApp.Counter do
        use Agent

        def start_link(_), do: Agent.start_link(fn -> 0 end)
        def get(pid), do: Agent.get(pid, & &1)
      end
      """

      [diag] = assert_flagged(OpaqueProcessState, code)
      assert diag.rule_id == "CE-29"
    end

    test "does NOT fire when format_status/1 is defined" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def init(opts), do: {:ok, opts}

        @impl true
        def format_status(%{state: state}) do
          %{state: %{state | secret_token: "[REDACTED]"}}
        end
      end
      """

      assert_clean(OpaqueProcessState, code)
    end

    test "does NOT fire on regular module (no use GenServer/Agent/:gen_statem)" do
      code = ~S"""
      defmodule MyApp.Util do
        def a(x), do: x
      end
      """

      assert_clean(OpaqueProcessState, code)
    end

    test "does NOT fire when @archdo_opaque_state is set" do
      code = ~S"""
      defmodule MyApp.Vault do
        use GenServer
        @archdo_opaque_state "contains operator secrets — operators run with elevated access"

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def init(opts), do: {:ok, opts}
      end
      """

      assert_clean(OpaqueProcessState, code)
    end

    test "fires on @behaviour :gen_statem without format_status/1" do
      code = ~S"""
      defmodule MyApp.Fsm do
        @behaviour :gen_statem

        def callback_mode, do: :state_functions
        def init(opts), do: {:ok, :idle, opts}
      end
      """

      [diag] = assert_flagged(OpaqueProcessState, code)
      assert diag.rule_id == "CE-29"
    end

    test "Archdo.Compiled.Collector is exempt via @archdo_opaque_state" do
      # Self-analysis guard: Collector is a transient compilation buffer.
      # Holds tracer events in memory while compilation runs; nothing
      # external observes its state. Exempt via @archdo_opaque_state.
      ast =
        "lib/archdo/compiled/collector.ex"
        |> File.read!()
        |> Code.string_to_quoted!()

      diags = OpaqueProcessState.analyze("lib/archdo/compiled/collector.ex", ast, [])
      assert diags == []
    end
  end
end
