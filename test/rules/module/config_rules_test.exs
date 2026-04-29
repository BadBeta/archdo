defmodule Archdo.Rules.Module.ConfigRulesTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.{LibConfigViaArgs, ScatteredConfig}

  describe "3.2 ScatteredConfig" do
    test "flags System.get_env in module code" do
      code = ~S"""
      defmodule MyApp.Mailer do
        def api_key, do: System.get_env("SENDGRID_KEY")
      end
      """

      diags = assert_flagged(ScatteredConfig, code)
      assert hd(diags).message =~ "System.get_env"
    end

    test "ignores test files" do
      code = ~S"""
      defmodule MyApp.MailerTest do
        def api_key, do: System.get_env("SENDGRID_KEY")
      end
      """

      assert_clean(ScatteredConfig, code, file: "test/mailer_test.exs")
    end
  end

  describe "3.3 LibConfigViaArgs" do
    test "flags Application.get_env in regular module" do
      code = ~S"""
      defmodule MyApp.Notifier do
        def send(msg) do
          config = Application.get_env(:my_app, :notifier)
          do_send(config, msg)
        end
      end
      """

      diags = assert_flagged(LibConfigViaArgs, code)
      assert hd(diags).message =~ "Application.get_env"
    end

    test "allows Application.get_env in Application module" do
      code = ~S"""
      defmodule MyApp.Application do
        use Application
        def start(_type, _args) do
          config = Application.get_env(:my_app, :settings)
          children = [{MyApp.Worker, config}]
          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end
      """

      assert_clean(LibConfigViaArgs, code)
    end

    test "allows Application.get_env in Mix tasks (operational layer)" do
      code = ~S"""
      defmodule Mix.Tasks.MyApp.Sync do
        use Mix.Task
        def run(_) do
          config = Application.get_env(:my_app, :sync)
          IO.inspect(config)
        end
      end
      """

      assert_clean(LibConfigViaArgs, code, file: "lib/mix/tasks/my_app.sync.ex")
    end
  end
end
