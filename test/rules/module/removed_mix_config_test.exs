defmodule Archdo.Rules.Module.RemovedMixConfigTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.RemovedMixConfig

  describe "analyze/3 — removed Mix.Config API" do
    test "flags `use Mix.Config` in config/config.exs" do
      code = ~S"""
      use Mix.Config

      config :my_app, key: :value
      """

      diags = assert_flagged(RemovedMixConfig, code, file: "config/config.exs")
      diag = hd(diags)
      assert diag.severity == :error
      assert diag.title =~ "Mix.Config"
      assert diag.message =~ "removed"
    end

    test "flags `import Mix.Config` in config/runtime.exs" do
      code = ~S"""
      import Mix.Config

      if config_env() == :prod do
        config :my_app, secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
      end
      """

      diags = assert_flagged(RemovedMixConfig, code, file: "config/runtime.exs")
      assert hd(diags).severity == :error
    end

    test "flags `use Mix.Config` in config/dev.exs" do
      code = ~S"""
      use Mix.Config

      config :my_app, MyAppWeb.Endpoint, debug_errors: true
      """

      assert_flagged(RemovedMixConfig, code, file: "config/dev.exs")
    end

    test "allows the modern `import Config`" do
      code = ~S"""
      import Config

      config :my_app, key: :value
      """

      assert_clean(RemovedMixConfig, code, file: "config/config.exs")
    end

    test "allows config files with neither (e.g., delegates everything via import_config)" do
      code = ~S"""
      import Config

      import_config "#{config_env()}.exs"
      """

      assert_clean(RemovedMixConfig, code, file: "config/config.exs")
    end

    test "skips files outside config/ paths" do
      # `use Mix.Config` in a regular .ex file would itself be a
      # different bug (it's not even valid in module bodies). But
      # this rule is scoped to config files — module-body checks
      # belong to other rules.
      code = ~S"""
      defmodule MyApp.Foo do
        use Mix.Config
      end
      """

      assert_clean(RemovedMixConfig, code, file: "lib/my_app/foo.ex")
    end

    test "matches nested config paths (apps/*/config/...)" do
      # Umbrella projects have config files under apps/<child>/config/
      code = ~S"""
      use Mix.Config
      config :child_app, key: :value
      """

      assert_flagged(RemovedMixConfig, code, file: "apps/my_app/config/config.exs")
    end

    test "skips files in `_build/` (build artifacts)" do
      code = ~S"""
      use Mix.Config
      """

      assert_clean(RemovedMixConfig, code, file: "_build/dev/lib/foo/config/config.exs")
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert RemovedMixConfig.id() == "3.7"
    end

    test "description mentions Mix.Config" do
      assert RemovedMixConfig.description() =~ "Mix.Config"
    end
  end
end
