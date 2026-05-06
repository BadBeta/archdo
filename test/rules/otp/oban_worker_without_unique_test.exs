defmodule Archdo.Rules.OTP.ObanWorkerWithoutUniqueTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.ObanWorkerWithoutUnique

  describe "analyze/3" do
    test "flags Oban.Worker `use` without `unique:` option" do
      code = ~S"""
      defmodule MyApp.Workers.SendWelcomeEmail do
        use Oban.Worker, queue: :mailers, max_attempts: 3

        @impl true
        def perform(%Oban.Job{args: %{"user_id" => id}}) do
          MyApp.Mailer.send_welcome(id)
          :ok
        end
      end
      """

      diags =
        assert_flagged(ObanWorkerWithoutUnique, code,
          file: "lib/my_app/workers/send_welcome_email.ex"
        )

      assert hd(diags).rule_id == "5.67"
    end

    test "ignores Oban.Worker with `unique:` option" do
      code = ~S"""
      defmodule MyApp.Workers.SendWelcomeEmail do
        use Oban.Worker,
          queue: :mailers,
          unique: [period: 60, fields: [:args]]

        @impl true
        def perform(%Oban.Job{}), do: :ok
      end
      """

      assert_clean(ObanWorkerWithoutUnique, code,
        file: "lib/my_app/workers/send_welcome_email.ex"
      )
    end

    test "ignores modules that don't use Oban.Worker" do
      code = ~S"""
      defmodule MyApp.Service do
        use GenServer
      end
      """

      assert_clean(ObanWorkerWithoutUnique, code, file: "lib/my_app/service.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use Oban.Worker, queue: :test
      end
      """

      assert_clean(ObanWorkerWithoutUnique, code, file: "test/worker_test.exs")
    end
  end
end
