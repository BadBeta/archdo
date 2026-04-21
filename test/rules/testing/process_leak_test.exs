defmodule Archdo.Rules.Testing.ProcessLeakTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.ProcessLeak

  describe "analyze/3" do
    test "flags GenServer.start_link in test file" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "worker processes messages" do
          {:ok, pid} = GenServer.start_link(MyApp.Worker, [])
          GenServer.call(pid, :ping)
        end
      end
      """

      diags = assert_flagged(ProcessLeak, code, file: "test/worker_test.exs")
      diag = hd(diags)
      assert diag.severity == :info
      assert diag.rule_id == "7.26"
    end

    test "flags Module.start_link in test file" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "worker starts" do
          {:ok, pid} = MyApp.Worker.start_link([])
          assert Process.alive?(pid)
        end
      end
      """

      diags = assert_flagged(ProcessLeak, code, file: "test/worker_test.exs")
      assert length(diags) >= 1
    end

    test "flags Supervisor.start_link in test file" do
      code = ~S"""
      defmodule MyApp.SupervisorTest do
        use ExUnit.Case

        test "supervisor starts children" do
          {:ok, pid} = Supervisor.start_link([MyApp.Worker], strategy: :one_for_one)
          assert Process.alive?(pid)
        end
      end
      """

      diags = assert_flagged(ProcessLeak, code, file: "test/supervisor_test.exs")
      assert length(diags) >= 1
    end

    test "allows start_supervised! usage" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "worker processes messages" do
          pid = start_supervised!({MyApp.Worker, []})
          GenServer.call(pid, :ping)
        end
      end
      """

      assert_clean(ProcessLeak, code, file: "test/worker_test.exs")
    end

    test "skips non-test files" do
      code = ~S"""
      defmodule MyApp.Application do
        def start(_type, _args) do
          {:ok, pid} = GenServer.start_link(MyApp.Worker, [])
          {:ok, pid}
        end
      end
      """

      assert_clean(ProcessLeak, code, file: "lib/my_app/application.ex")
    end
  end
end
