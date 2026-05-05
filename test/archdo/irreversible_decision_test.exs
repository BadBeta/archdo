defmodule Archdo.IrreversibleDecisionTest do
  use ExUnit.Case, async: true

  alias Archdo.IrreversibleDecision

  defp parse(code) do
    {:ok, ast} = Code.string_to_quoted(code, columns: true, token_metadata: true)
    ast
  end

  describe "candidate?/3" do
    test "true for an Ecto schema (use Ecto.Schema)" do
      ast =
        parse(~S"""
        defmodule MyApp.User do
          use Ecto.Schema
        end
        """)

      assert IrreversibleDecision.candidate?("lib/my_app/user.ex", ast, [])
    end

    test "true for a Supervisor (use Supervisor)" do
      ast =
        parse(~S"""
        defmodule MyApp.Sup do
          use Supervisor
        end
        """)

      assert IrreversibleDecision.candidate?("lib/my_app/sup.ex", ast, [])
    end

    test "true for a DynamicSupervisor" do
      ast =
        parse(~S"""
        defmodule MyApp.DynSup do
          use DynamicSupervisor
        end
        """)

      assert IrreversibleDecision.candidate?("lib/my_app/dyn_sup.ex", ast, [])
    end

    test "true for a module that defines child_spec/1" do
      ast =
        parse(~S"""
        defmodule MyApp.Custom do
          def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
        end
        """)

      assert IrreversibleDecision.candidate?("lib/my_app/custom.ex", ast, [])
    end

    test "true when file is under a configured public_api_paths prefix" do
      ast =
        parse(~S"""
        defmodule MyApp.Public.Api do
          def hello, do: :world
        end
        """)

      assert IrreversibleDecision.candidate?("lib/my_app/public/api.ex", ast,
               public_api_paths: ["lib/my_app/public/"]
             )
    end

    test "false for an ordinary module" do
      ast =
        parse(~S"""
        defmodule MyApp.Plain do
          def f, do: 1
        end
        """)

      refute IrreversibleDecision.candidate?("lib/my_app/plain.ex", ast, [])
    end
  end

  describe "oban_worker?/1" do
    test "true for use Oban.Worker" do
      ast =
        parse(~S"""
        defmodule MyApp.SendEmail do
          use Oban.Worker
        end
        """)

      assert IrreversibleDecision.oban_worker?(ast)
    end

    test "true for use Oban.Worker with options" do
      ast =
        parse(~S"""
        defmodule MyApp.SendEmail do
          use Oban.Worker, queue: :emails, max_attempts: 5
        end
        """)

      assert IrreversibleDecision.oban_worker?(ast)
    end

    test "false for non-Oban modules" do
      ast =
        parse(~S"""
        defmodule MyApp.Plain do
          use GenServer
        end
        """)

      refute IrreversibleDecision.oban_worker?(ast)
    end
  end
end
