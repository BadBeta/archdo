defmodule Archdo.Rules.OTP.AgentMisuseTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.AgentMisuse

  test "flags Agent cache with more gets than updates" do
    code = ~S"""
    defmodule MyApp.Cache do
      use Agent

      def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
      def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))
      def get_all, do: Agent.get(__MODULE__, & &1)
      def put(key, val), do: Agent.update(__MODULE__, &Map.put(&1, key, val))
    end
    """

    diags = assert_flagged(AgentMisuse, code)
    diag = hd(diags)
    assert diag.rule_id == "5.3"
    assert diag.title == "Agent used as read-heavy cache"
    assert diag.context.get_count == 2
    assert diag.context.update_count == 1
  end

  test "ignores non-Agent modules" do
    code = ~S"""
    defmodule MyApp.Cache do
      use GenServer
      def init(_), do: {:ok, %{}}
    end
    """

    assert_clean(AgentMisuse, code)
  end
end
