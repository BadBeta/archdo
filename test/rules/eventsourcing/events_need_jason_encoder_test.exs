defmodule Archdo.Rules.EventSourcing.EventsNeedJasonEncoderTest do
  use Archdo.RuleCase

  alias Archdo.Rules.EventSourcing.EventsNeedJasonEncoder

  describe "analyze/3" do
    test "flags event struct without Jason.Encoder derivation" do
      code = ~S"""
      defmodule MyApp.Events.AccountOpened do
        defstruct [:account_id, :name]
      end
      """

      diags = assert_flagged(EventsNeedJasonEncoder, code)
      assert hd(diags).rule_id == "8.5"
      assert hd(diags).message =~ "Jason.Encoder"
    end

    test "allows event with @derive Jason.Encoder" do
      code = ~S"""
      defmodule MyApp.Events.AccountOpened do
        @derive Jason.Encoder
        defstruct [:account_id, :name]
      end
      """

      assert_clean(EventsNeedJasonEncoder, code)
    end

    test "ignores non-event modules" do
      code = ~S"""
      defmodule MyApp.Accounts.User do
        defstruct [:id, :name]
      end
      """

      assert_clean(EventsNeedJasonEncoder, code)
    end
  end

  describe "FP filters — non-event-struct modules in Event* namespace" do
    # GenServer in `*.Event.*` namespace — NOT an event, has internal state struct.
    # Mirrors Commanded.Event.Handler which has `use GenServer` + defstruct for
    # GenServer state; not a persisted event.
    test "does not flag GenServer with internal state struct in Event namespace" do
      code = ~S"""
      defmodule MyApp.Event.Handler do
        use GenServer

        defstruct [:application, :handler_module, :consistency]

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

        @impl true
        def init(opts), do: {:ok, %__MODULE__{application: opts[:application]}}
      end
      """

      assert_clean(EventsNeedJasonEncoder, code)
    end

    # FailureContext, ErrorContext, etc. — runtime context structs passed
    # to handler callbacks. NOT events.
    test "does not flag `*.FailureContext` (failure-data struct, not event)" do
      code = ~S"""
      defmodule MyApp.Event.FailureContext do
        defstruct [:application, :handler_name, :error]
      end
      """

      assert_clean(EventsNeedJasonEncoder, code)
    end

    # Subscriber / ProcessManager / Aggregate / Router / Application —
    # Commanded infrastructure terms; structs in these modules are
    # internal state, not events.
    test "does not flag `*.Subscriber` infrastructure module" do
      code = ~S"""
      defmodule MyApp.Event.Subscriber do
        defstruct [:subscription_name, :pid]
      end
      """

      assert_clean(EventsNeedJasonEncoder, code)
    end

    test "does not flag `*.ProcessManager` infrastructure module" do
      code = ~S"""
      defmodule MyApp.Events.OrderProcessManager do
        defstruct [:order_id, :status]
      end
      """

      assert_clean(EventsNeedJasonEncoder, code)
    end

    test "does not flag `*.Router` infrastructure module" do
      code = ~S"""
      defmodule MyApp.Events.Router do
        defstruct [:routes]
      end
      """

      assert_clean(EventsNeedJasonEncoder, code)
    end
  end
end
