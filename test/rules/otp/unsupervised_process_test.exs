defmodule Archdo.Rules.OTP.UnsupervisedProcessTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.UnsupervisedProcess

  describe "bare spawn" do
    test "flags spawn/1" do
      code = ~S"""
      defmodule MyApp.Worker do
        def start do
          spawn(fn -> loop() end)
        end
      end
      """

      diags = assert_flagged(UnsupervisedProcess, code)
      assert hd(diags).severity == :warning
      assert hd(diags).rule_id == "5.1"
    end

    test "flags spawn_link/1" do
      code = ~S"""
      defmodule MyApp.Worker do
        def start do
          spawn_link(fn -> loop() end)
        end
      end
      """

      assert_flagged(UnsupervisedProcess, code)
    end

    test "ignores test files" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        def start do
          spawn(fn -> loop() end)
        end
      end
      """

      assert_clean(UnsupervisedProcess, code, file: "test/worker_test.exs")
    end
  end

  describe "unlinked GenServer.start" do
    test "flags GenServer.start" do
      code = ~S"""
      defmodule MyApp.Worker do
        def go do
          GenServer.start(MyApp.Server, [])
        end
      end
      """

      diags = assert_flagged(UnsupervisedProcess, code)
      assert hd(diags).message =~ "start_link"
    end

    test "allows GenServer.start_link" do
      code = ~S"""
      defmodule MyApp.Worker do
        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts)
        end
      end
      """

      assert_clean(UnsupervisedProcess, code)
    end
  end
end
