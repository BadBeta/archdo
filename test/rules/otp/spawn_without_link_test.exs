defmodule Archdo.Rules.OTP.SpawnWithoutLinkTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.SpawnWithoutLink

  test "flags bare spawn/1" do
    code = ~S"""
    defmodule MyApp.Worker do
      def do_work(data) do
        spawn(fn -> process(data) end)
      end
    end
    """

    assert_flagged(SpawnWithoutLink, code)
  end

  test "allows spawn_link" do
    code = ~S"""
    defmodule MyApp.Worker do
      def do_work(data) do
        spawn_link(fn -> process(data) end)
      end
    end
    """

    assert_clean(SpawnWithoutLink, code)
  end

  test "ignores test files" do
    code = ~S"""
    defmodule MyApp.WorkerTest do
      def test_spawn do
        spawn(fn -> :ok end)
      end
    end
    """

    assert_clean(SpawnWithoutLink, code, file: "test/worker_test.exs")
  end
end
