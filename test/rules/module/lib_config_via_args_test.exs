defmodule Archdo.Rules.Module.LibConfigViaArgsTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.LibConfigViaArgs

  defp parse(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    ast
  end

  describe "analyze/3 — flags Application.* config reads" do
    test "flags Application.get_env" do
      ast =
        parse(~S"""
        defmodule MyLib.Worker do
          def start, do: Application.get_env(:my_lib, :url)
        end
        """)

      diags = LibConfigViaArgs.analyze("lib/my_lib/worker.ex", ast, [])
      assert [d] = diags
      assert d.context.call == "Application.get_env"
    end

    test "flags Application.fetch_env" do
      ast =
        parse(~S"""
        defmodule MyLib.Worker do
          def start, do: Application.fetch_env(:my_lib, :url)
        end
        """)

      assert [d] = LibConfigViaArgs.analyze("lib/my_lib/worker.ex", ast, [])
      assert d.context.call == "Application.fetch_env"
    end

    test "flags Application.fetch_env!" do
      ast =
        parse(~S"""
        defmodule MyLib.Worker do
          def start, do: Application.fetch_env!(:my_lib, :url)
        end
        """)

      assert [d] = LibConfigViaArgs.analyze("lib/my_lib/worker.ex", ast, [])
      assert d.context.call == "Application.fetch_env!"
    end

    test "flags multiple distinct calls" do
      ast =
        parse(~S"""
        defmodule MyLib.Worker do
          def url, do: Application.get_env(:my_lib, :url)
          def port, do: Application.fetch_env!(:my_lib, :port)
        end
        """)

      diags = LibConfigViaArgs.analyze("lib/my_lib/worker.ex", ast, [])
      assert length(diags) == 2
    end
  end

  describe "analyze/3 — exempts files that legitimately read Application env" do
    test "test file is exempt" do
      ast =
        parse(~S"""
        defmodule MyLib.WorkerTest do
          def setup, do: Application.get_env(:my_lib, :url)
        end
        """)

      assert [] = LibConfigViaArgs.analyze("test/my_lib/worker_test.exs", ast, [])
    end

    test "module that `use Application` is exempt" do
      ast =
        parse(~S"""
        defmodule MyApp.Application do
          use Application
          def start(_type, _args) do
            url = Application.get_env(:my_app, :url)
            Supervisor.start_link([], strategy: :one_for_one)
          end
        end
        """)

      assert [] = LibConfigViaArgs.analyze("lib/my_app/application.ex", ast, [])
    end

    test "file ending in config.ex is exempt" do
      ast =
        parse(~S"""
        defmodule MyLib.Config do
          def url, do: Application.get_env(:my_lib, :url)
        end
        """)

      assert [] = LibConfigViaArgs.analyze("lib/my_lib/config.ex", ast, [])
    end

    test "file under /config/ path is exempt" do
      ast =
        parse(~S"""
        defmodule MyLib.Config.Reader do
          def url, do: Application.get_env(:my_lib, :url)
        end
        """)

      assert [] = LibConfigViaArgs.analyze("lib/my_lib/config/reader.ex", ast, [])
    end

    test "module named Settings is exempt" do
      ast =
        parse(~S"""
        defmodule MyLib.Settings do
          def url, do: Application.get_env(:my_lib, :url)
        end
        """)

      assert [] = LibConfigViaArgs.analyze("lib/my_lib/settings.ex", ast, [])
    end

    test "module named Configuration is exempt" do
      ast =
        parse(~S"""
        defmodule MyLib.Configuration do
          def url, do: Application.get_env(:my_lib, :url)
        end
        """)

      assert [] = LibConfigViaArgs.analyze("lib/my_lib/configuration.ex", ast, [])
    end

    test "operational layer (passed via opts) is exempt" do
      ast =
        parse(~S"""
        defmodule MyApp.Release do
          def setup, do: Application.fetch_env!(:my_app, :url)
        end
        """)

      assert [] =
               LibConfigViaArgs.analyze("lib/my_app/release.ex", ast,
                 phoenix: %{layer: :operational}
               )
    end
  end
end
