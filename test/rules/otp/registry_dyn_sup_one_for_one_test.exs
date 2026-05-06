defmodule Archdo.Rules.OTP.RegistryDynSupOneForOneTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.RegistryDynSupOneForOne

  test "fires when Registry + DynamicSupervisor are children under :one_for_one" do
    code = ~S"""
    defmodule MyApp.Sup do
      use Supervisor

      @impl true
      def init(_) do
        children = [
          {Registry, keys: :unique, name: MyApp.Registry},
          {DynamicSupervisor, name: MyApp.DynSup}
        ]

        Supervisor.init(children, strategy: :one_for_one)
      end
    end
    """

    diags = assert_flagged(RegistryDynSupOneForOne, code)
    assert hd(diags).rule_id == "5.66"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "rest_for_one"
  end

  test "does NOT fire when strategy is :rest_for_one" do
    code = ~S"""
    defmodule MyApp.Sup do
      use Supervisor

      @impl true
      def init(_) do
        children = [
          {Registry, keys: :unique, name: MyApp.Registry},
          {DynamicSupervisor, name: MyApp.DynSup}
        ]

        Supervisor.init(children, strategy: :rest_for_one)
      end
    end
    """

    assert_clean(RegistryDynSupOneForOne, code)
  end

  test "does NOT fire when only DynamicSupervisor (no Registry pair)" do
    code = ~S"""
    defmodule MyApp.Sup do
      use Supervisor

      @impl true
      def init(_) do
        children = [{DynamicSupervisor, name: MyApp.DynSup}]
        Supervisor.init(children, strategy: :one_for_one)
      end
    end
    """

    assert_clean(RegistryDynSupOneForOne, code)
  end
end
