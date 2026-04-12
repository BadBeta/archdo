defmodule Archdo.Rules.OTP.FlatSupervisionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.FlatSupervision

  test "flags supervisor with too many children" do
    children = Enum.map_join(1..9, ", ", fn i -> "Worker#{i}" end)

    code = """
    defmodule MyApp.Application do
      def start(_type, _args) do
        children = [#{children}]
        Supervisor.start_link(children, strategy: :one_for_one)
      end
    end
    """

    diags = assert_flagged(FlatSupervision, code)
    assert hd(diags).message =~ "9 direct children"
  end

  test "allows supervisor with few children" do
    code = ~S"""
    defmodule MyApp.Application do
      def start(_type, _args) do
        children = [MyApp.Repo, MyApp.Endpoint]
        Supervisor.start_link(children, strategy: :one_for_one)
      end
    end
    """

    assert_clean(FlatSupervision, code)
  end
end
