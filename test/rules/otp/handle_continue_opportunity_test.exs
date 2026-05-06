defmodule Archdo.Rules.OTP.HandleContinueOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.HandleContinueOpportunity

  test "fires when init/1 body does heavy work (Repo / HTTP / File / sleep) before returning" do
    code = ~S"""
    defmodule MyApp.Cache do
      use GenServer

      @impl true
      def init(_args) do
        users = MyApp.Repo.all(User)
        {:ok, %{users: users}}
      end
    end
    """

    diags = assert_flagged(HandleContinueOpportunity, code)
    assert hd(diags).rule_id == "5.62"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "handle_continue"
  end

  test "does NOT fire when init/1 returns `{:ok, state, {:continue, ...}}` already" do
    code = ~S"""
    defmodule MyApp.Cache do
      use GenServer

      @impl true
      def init(_args), do: {:ok, %{users: nil}, {:continue, :load}}

      @impl true
      def handle_continue(:load, state) do
        users = MyApp.Repo.all(User)
        {:noreply, %{state | users: users}}
      end
    end
    """

    assert_clean(HandleContinueOpportunity, code)
  end

  test "does NOT fire on a trivial init/1 (no heavy work)" do
    code = ~S"""
    defmodule MyApp.Echo do
      use GenServer

      @impl true
      def init(state), do: {:ok, state}
    end
    """

    assert_clean(HandleContinueOpportunity, code)
  end
end
