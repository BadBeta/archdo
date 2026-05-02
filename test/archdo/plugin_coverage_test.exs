defmodule Archdo.PluginCoverageTest do
  use ExUnit.Case, async: true

  alias Archdo.PluginCoverage

  defp parse(code, file) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {file, ast}
  end

  describe "scan/1 — discovers plug modules with telemetry / log calls" do
    test "detects a plug module that emits :telemetry.span" do
      file_asts = [
        parse(
          """
          defmodule MyAppWeb.Plugs.Telemetry do
            @behaviour Plug

            def init(opts), do: opts

            def call(conn, _opts) do
              :telemetry.span([:my_app_web, :request], %{}, fn ->
                {conn, %{}}
              end)
            end
          end
          """,
          "lib/my_app_web/plugs/telemetry.ex"
        )
      ]

      coverage = PluginCoverage.scan(file_asts)
      assert "MyAppWeb.Plugs.Telemetry" in coverage.telemetry_plugs
      refute "MyAppWeb.Plugs.Telemetry" in coverage.log_plugs
    end

    test "detects a plug module that emits :telemetry.execute" do
      file_asts = [
        parse(
          """
          defmodule MyAppWeb.Plugs.Metrics do
            def init(opts), do: opts

            def call(conn, _opts) do
              :telemetry.execute([:my_app_web, :req], %{}, %{})
              conn
            end
          end
          """,
          "lib/my_app_web/plugs/metrics.ex"
        )
      ]

      coverage = PluginCoverage.scan(file_asts)
      assert "MyAppWeb.Plugs.Metrics" in coverage.telemetry_plugs
    end

    test "detects a plug module that emits Logger.error" do
      file_asts = [
        parse(
          """
          defmodule MyAppWeb.Plugs.ErrorLog do
            require Logger

            def init(opts), do: opts

            def call(conn, _opts) do
              Logger.error("request failed", path: conn.request_path)
              conn
            end
          end
          """,
          "lib/my_app_web/plugs/error_log.ex"
        )
      ]

      coverage = PluginCoverage.scan(file_asts)
      assert "MyAppWeb.Plugs.ErrorLog" in coverage.log_plugs
      refute "MyAppWeb.Plugs.ErrorLog" in coverage.telemetry_plugs
    end

    test "does NOT classify a non-plug module (no call/2) as a plug" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Helper do
            require Logger

            def go(x) do
              Logger.error("oops", x: x)
              :telemetry.execute([:helper], %{}, %{})
              x
            end
          end
          """,
          "lib/my_app/helper.ex"
        )
      ]

      coverage = PluginCoverage.scan(file_asts)
      refute "MyApp.Helper" in coverage.telemetry_plugs
      refute "MyApp.Helper" in coverage.log_plugs
    end

    test "does NOT classify a plug module without telemetry/log as covering" do
      file_asts = [
        parse(
          """
          defmodule MyAppWeb.Plugs.Bare do
            def init(opts), do: opts
            def call(conn, _opts), do: conn
          end
          """,
          "lib/my_app_web/plugs/bare.ex"
        )
      ]

      coverage = PluginCoverage.scan(file_asts)
      refute "MyAppWeb.Plugs.Bare" in coverage.telemetry_plugs
      refute "MyAppWeb.Plugs.Bare" in coverage.log_plugs
    end

    test "returns empty index for project with no modules" do
      coverage = PluginCoverage.scan([])
      assert coverage == %{telemetry_plugs: [], log_plugs: []}
    end

    test "discovers plugs across multiple files" do
      file_asts = [
        parse(
          """
          defmodule MyAppWeb.Plugs.Telemetry do
            def init(o), do: o
            def call(conn, _) do
              :telemetry.execute([:a], %{}, %{})
              conn
            end
          end
          """,
          "lib/my_app_web/plugs/telemetry.ex"
        ),
        parse(
          """
          defmodule MyAppWeb.Plugs.Audit do
            require Logger
            def init(o), do: o
            def call(conn, _) do
              Logger.warning("audit", path: conn.request_path)
              conn
            end
          end
          """,
          "lib/my_app_web/plugs/audit.ex"
        )
      ]

      coverage = PluginCoverage.scan(file_asts)
      assert "MyAppWeb.Plugs.Telemetry" in coverage.telemetry_plugs
      assert "MyAppWeb.Plugs.Audit" in coverage.log_plugs
    end
  end
end
