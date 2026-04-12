defmodule Archdo.Rules.EventSourcing.EventSourcingTest do
  use Archdo.RuleCase

  alias Archdo.Rules.EventSourcing.{CommandEventNaming, PureAggregateApply, ImmutableEvents}

  describe "8.1 CommandEventNaming" do
    test "flags command not in imperative form" do
      code = ~S"""
      defmodule MyApp.Commands.AccountCreated do
        defstruct [:account_id, :name]
      end
      """

      diags = assert_flagged(CommandEventNaming, code)
      diag = hd(diags)
      assert diag.rule_id == "8.1"
      assert diag.title == "Command named in past tense"
      assert diag.context.kind == :command
      assert length(diag.alternatives) >= 1
    end

    test "allows properly named command" do
      code = ~S"""
      defmodule MyApp.Commands.CreateAccount do
        defstruct [:name, :email]
      end
      """

      assert_clean(CommandEventNaming, code)
    end

    test "flags event not in past tense" do
      code = ~S"""
      defmodule MyApp.Events.CreateAccount do
        defstruct [:account_id]
      end
      """

      diags = assert_flagged(CommandEventNaming, code)
      diag = hd(diags)
      assert diag.rule_id == "8.1"
      assert diag.title == "Event named in imperative form"
      assert diag.context.kind == :event
    end

    test "allows properly named event" do
      code = ~S"""
      defmodule MyApp.Events.AccountCreated do
        defstruct [:account_id, :name]
      end
      """

      assert_clean(CommandEventNaming, code)
    end

    test "ignores non-CQRS modules" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create(attrs), do: {:ok, attrs}
      end
      """

      assert_clean(CommandEventNaming, code)
    end
  end

  describe "8.2 PureAggregateApply" do
    test "flags side effects in apply/2" do
      code = ~S"""
      defmodule MyApp.Account do
        def execute(%{}, %CreateAccount{} = cmd), do: %AccountCreated{name: cmd.name}

        def apply(%{} = state, %AccountCreated{} = event) do
          Logger.info("Account created!")
          %{state | name: event.name}
        end
      end
      """

      diags = assert_flagged(PureAggregateApply, code)
      diag = hd(diags)
      assert diag.severity == :error
      assert diag.rule_id == "8.2"
      assert diag.title == "Side effect in aggregate apply/2"
      assert diag.message =~ "apply/2"
      assert diag.message =~ "Logger"
      assert diag.why =~ "rehydration"
      assert length(diag.alternatives) >= 1
      assert hd(diag.alternatives).summary =~ "execute/2"
      assert "ARCHITECTURE_RULES.md#8.2" in diag.references
      assert diag.context.function == "apply/2"
    end

    test "allows pure apply/2" do
      code = ~S"""
      defmodule MyApp.Account do
        def execute(%{}, %CreateAccount{} = cmd), do: %AccountCreated{name: cmd.name}

        def apply(%{} = state, %AccountCreated{} = event) do
          %{state | name: event.name}
        end
      end
      """

      assert_clean(PureAggregateApply, code)
    end
  end

  describe "8.3 ImmutableEvents" do
    test "flags event module without defstruct" do
      code = ~S"""
      defmodule MyApp.Events.AccountCreated do
        def new(attrs), do: Map.new(attrs)
      end
      """

      diags = assert_flagged(ImmutableEvents, code)
      diag = hd(diags)
      assert diag.rule_id == "8.3"
      assert diag.title == "Event without struct definition"
      assert diag.message =~ "does not define a struct"
      assert "ARCHITECTURE_RULES.md#8.3" in diag.references
    end

    test "allows event with defstruct" do
      code = ~S"""
      defmodule MyApp.Events.AccountCreated do
        defstruct [:account_id, :name, :email]
      end
      """

      assert_clean(ImmutableEvents, code)
    end
  end
end
