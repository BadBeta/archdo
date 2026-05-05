defmodule Archdo.Rules.OTP.MissingTelemetryObanWorkerTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.MissingTelemetryObanWorker

  test "fires on `use Oban.Worker` without telemetry or Logger calls in perform/1" do
    code = ~S"""
    defmodule MyApp.Workers.SendEmail do
      use Oban.Worker, queue: :emails

      @impl true
      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        user = MyApp.Accounts.get_user!(user_id)
        MyApp.Mailer.send_welcome(user)
        :ok
      end
    end
    """

    diags = assert_flagged(MissingTelemetryObanWorker, code)
    assert hd(diags).rule_id == "5.56"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "telemetry"
  end

  test "does NOT fire when perform body calls :telemetry.span" do
    code = ~S"""
    defmodule MyApp.Workers.SendEmail do
      use Oban.Worker, queue: :emails

      @impl true
      def perform(%Oban.Job{args: args}) do
        :telemetry.span([:my_app, :send_email], %{}, fn ->
          do_send(args)
          {:ok, %{}}
        end)
      end

      defp do_send(_args), do: :ok
    end
    """

    assert_clean(MissingTelemetryObanWorker, code)
  end

  test "does NOT fire when perform body calls Logger.info (any observability counts)" do
    code = ~S"""
    defmodule MyApp.Workers.SendEmail do
      use Oban.Worker, queue: :emails
      require Logger

      @impl true
      def perform(%Oban.Job{args: args}) do
        Logger.info("send_email start", args: args)
        :ok
      end
    end
    """

    assert_clean(MissingTelemetryObanWorker, code)
  end

  test "does NOT fire when @archdo_no_observability marker is set" do
    code = ~S"""
    defmodule MyApp.Workers.SendEmail do
      use Oban.Worker, queue: :emails
      @archdo_no_observability "fire-and-forget cleanup; nothing to monitor"

      @impl true
      def perform(%Oban.Job{args: _}) do
        :ok
      end
    end
    """

    assert_clean(MissingTelemetryObanWorker, code)
  end
end
