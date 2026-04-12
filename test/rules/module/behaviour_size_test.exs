defmodule Archdo.Rules.Module.BehaviourSizeTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.BehaviourSize

  test "flags behaviour with too many required callbacks" do
    code = ~S"""
    defmodule MyApp.GodBehaviour do
      @callback create(term()) :: term()
      @callback read(term()) :: term()
      @callback update(term(), term()) :: term()
      @callback delete(term()) :: term()
      @callback list() :: [term()]
      @callback search(String.t()) :: [term()]
    end
    """

    diags = assert_flagged(BehaviourSize, code)
    assert hd(diags).message =~ "6 required callbacks"
  end

  test "allows small behaviour" do
    code = ~S"""
    defmodule MyApp.Notifier do
      @callback send_notification(String.t(), String.t()) :: :ok | {:error, term()}
    end
    """

    assert_clean(BehaviourSize, code)
  end

  test "excludes optional callbacks from count" do
    code = ~S"""
    defmodule MyApp.Worker do
      @callback run(term()) :: term()
      @callback setup() :: :ok
      @callback teardown() :: :ok
      @callback status() :: atom()
      @callback retry(term()) :: term()
      @callback log(String.t()) :: :ok
      @optional_callbacks [setup: 0, teardown: 0, log: 1]
    end
    """

    assert_clean(BehaviourSize, code)
  end
end
