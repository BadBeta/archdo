defmodule Archdo.Rules.OTP.SendSelfInInitTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.SendSelfInInit

  test "flags send(self(), ...) in init" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer

      def init(args) do
        send(self(), :post_init)
        {:ok, %{}}
      end
    end
    """

    diags = assert_flagged(SendSelfInInit, code)
    diag = hd(diags)
    assert diag.severity == :warning
    assert diag.rule_id == "5.12"
    assert diag.title == "send(self()) in init/1"
  end

  test "allows handle_continue pattern" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer

      def init(args) do
        {:ok, %{}, {:continue, :post_init}}
      end

      def handle_continue(:post_init, state) do
        {:noreply, load_data(state)}
      end
    end
    """

    assert_clean(SendSelfInInit, code)
  end

  test "ignores non-GenServer modules" do
    code = ~S"""
    defmodule MyApp.Worker do
      def init(args) do
        send(self(), :go)
        {:ok, args}
      end
    end
    """

    assert_clean(SendSelfInInit, code)
  end
end
