defmodule Archdo.Rules.OTP.MaxRestartsTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.MaxRestarts

  test "flags Supervisor.start_link without max_restarts" do
    code = ~S"""
    defmodule MyApp.Supervisor do
      def start_link(opts) do
        children = [{MyWorker, opts}]
        Supervisor.start_link(children, strategy: :one_for_one)
      end
    end
    """

    assert_flagged(MaxRestarts, code)
  end

  test "allows Supervisor.start_link with max_restarts" do
    code = ~S"""
    defmodule MyApp.Supervisor do
      def start_link(opts) do
        children = [{MyWorker, opts}]
        Supervisor.start_link(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
      end
    end
    """

    assert_clean(MaxRestarts, code)
  end

  test "flags DynamicSupervisor.start_link without max_restarts" do
    code = ~S"""
    defmodule MyApp.DynSup do
      def start_link(opts) do
        DynamicSupervisor.start_link(strategy: :one_for_one)
      end
    end
    """

    assert_flagged(MaxRestarts, code)
  end
end
