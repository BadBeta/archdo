defmodule Archdo.Rules.OTP.ObanWorkerWithoutMaxAttemptsTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.ObanWorkerWithoutMaxAttempts

  describe "analyze/3" do
    test "flags Oban.Worker without `max_attempts:`" do
      code = ~S"""
      defmodule MyApp.Workers.SendEmail do
        use Oban.Worker, queue: :mailers, unique: [period: 60]

        @impl true
        def perform(%Oban.Job{}), do: :ok
      end
      """

      diags =
        assert_flagged(ObanWorkerWithoutMaxAttempts, code,
          file: "lib/my_app/workers/send_email.ex"
        )

      assert hd(diags).rule_id == "5.68"
    end

    test "ignores Oban.Worker with `max_attempts:`" do
      code = ~S"""
      defmodule MyApp.Workers.SendEmail do
        use Oban.Worker, queue: :mailers, max_attempts: 5
      end
      """

      assert_clean(ObanWorkerWithoutMaxAttempts, code,
        file: "lib/my_app/workers/send_email.ex"
      )
    end

    test "ignores non-Oban modules" do
      code = ~S"""
      defmodule MyApp.Service do
        use GenServer
      end
      """

      assert_clean(ObanWorkerWithoutMaxAttempts, code, file: "lib/my_app/service.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use Oban.Worker, queue: :test
      end
      """

      assert_clean(ObanWorkerWithoutMaxAttempts, code, file: "test/worker_test.exs")
    end
  end
end
