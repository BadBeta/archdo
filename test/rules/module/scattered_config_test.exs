defmodule Archdo.Rules.Module.ScatteredConfigTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ScatteredConfig

  describe "analyze/3 — System.get_env" do
    test "flags System.get_env in lib/ module" do
      code = ~S"""
      defmodule MyApp.Worker do
        def url do
          System.get_env("API_URL")
        end
      end
      """

      diags = assert_flagged(ScatteredConfig, code, file: "lib/my_app/worker.ex")
      diag = hd(diags)
      assert diag.severity == :warning
      assert diag.rule_id == "3.2"
    end

    test "flags System.fetch_env! in lib/ module" do
      code = ~S"""
      defmodule MyApp.Worker do
        def url, do: System.fetch_env!("API_URL")
      end
      """

      assert_flagged(ScatteredConfig, code, file: "lib/my_app/worker.ex")
    end
  end

  describe "analyze/3 — Application config functions" do
    test "flags Application.get_env in business-logic module" do
      code = ~S"""
      defmodule MyApp.Worker do
        def timeout do
          Application.get_env(:my_app, :timeout, 5_000)
        end
      end
      """

      diags = assert_flagged(ScatteredConfig, code, file: "lib/my_app/worker.ex")
      assert hd(diags).rule_id == "3.2"
    end

    test "flags Application.fetch_env! in business-logic module" do
      code = ~S"""
      defmodule MyApp.Worker do
        def url, do: Application.fetch_env!(:my_app, :api_url)
      end
      """

      assert_flagged(ScatteredConfig, code, file: "lib/my_app/worker.ex")
    end
  end

  describe "analyze/3 — file scoping" do
    test "skips test files" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        def url, do: System.get_env("API_URL")
      end
      """

      assert analyze(ScatteredConfig, code, file: "test/my_app/worker_test.exs") == []
    end

    test "skips config/ files" do
      code = ~S"""
      import Config
      config :my_app, :url, System.get_env("API_URL")
      """

      assert analyze(ScatteredConfig, code, file: "config/runtime.exs") == []
    end

    test "skips mix.exs" do
      code = ~S"""
      defmodule MyApp.MixProject do
        def env, do: System.get_env("MIX_ENV")
      end
      """

      assert analyze(ScatteredConfig, code, file: "mix.exs") == []
    end

    test "skips files ending in _config.ex (the centralized accessor module)" do
      code = ~S"""
      defmodule MyApp.Config do
        def url, do: System.get_env("API_URL")
        def timeout, do: Application.get_env(:my_app, :timeout)
      end
      """

      assert analyze(ScatteredConfig, code, file: "lib/my_app/app_config.ex") == []
    end

    test "skips files named config.ex (the canonical Config module)" do
      # `lib/my_app/config.ex` defining `MyApp.Config` is the most common
      # shape of the centralized accessor module; planning skill §10.5.1
      # treats this as the canonical home for application config reads.
      code = ~S"""
      defmodule MyApp.Config do
        def url, do: System.get_env("API_URL")
        def timeout, do: Application.get_env(:my_app, :timeout)
      end
      """

      assert analyze(ScatteredConfig, code, file: "lib/my_app/config.ex") == []
    end
  end

  describe "analyze/3 — clean cases" do
    test "does not flag a module without env reads" do
      code = ~S"""
      defmodule MyApp.Worker do
        def hello, do: "world"
      end
      """

      assert_clean(ScatteredConfig, code, file: "lib/my_app/worker.ex")
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert ScatteredConfig.id() == "3.2"
    end

    test "description mentions config" do
      assert ScatteredConfig.description() =~ "env" or
               ScatteredConfig.description() =~ "config"
    end
  end
end
