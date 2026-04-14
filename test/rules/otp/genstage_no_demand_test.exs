defmodule Archdo.Rules.OTP.GenstageNoDemandTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.GenstageNoDemand

  test "flags GenStage consumer without max_demand" do
    code = ~S"""
    defmodule MyConsumer do
      use GenStage

      def init(_) do
        {:consumer, %{}, subscribe_to: [MyProducer]}
      end
    end
    """

    assert_flagged(GenstageNoDemand, code)
  end

  test "allows GenStage consumer with max_demand" do
    code = ~S"""
    defmodule MyConsumer do
      use GenStage

      def init(_) do
        {:consumer, %{}, subscribe_to: [{MyProducer, max_demand: 10, min_demand: 5}]}
      end
    end
    """

    assert_clean(GenstageNoDemand, code)
  end

  test "ignores non-GenStage modules" do
    code = ~S"""
    defmodule MyWorker do
      use GenServer

      def init(_) do
        {:ok, %{}}
      end
    end
    """

    assert_clean(GenstageNoDemand, code)
  end
end
