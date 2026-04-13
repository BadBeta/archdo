defmodule Archdo.Rules.Module.MissingTelemetryTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.MissingTelemetry

  defp parse(code, file) do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true, token_metadata: true)
    {file, ast}
  end

  test "flags context facade without telemetry" do
    # Facade file at lib/my_app/accounts.ex
    facade = parse("""
      defmodule MyApp.Accounts do
        def create_user(attrs), do: :ok
        def get_user(id), do: nil
        def delete_user(id), do: :ok
      end
    """, "lib/my_app/accounts.ex")

    # Sub-module at lib/my_app/accounts/user.ex (proves accounts/ dir exists)
    sub = parse("""
      defmodule MyApp.Accounts.User do
        defstruct [:id, :name]
      end
    """, "lib/my_app/accounts/user.ex")

    diags = MissingTelemetry.analyze_project([facade, sub])
    assert length(diags) == 1
    assert hd(diags).rule_id == "4.19"
    assert hd(diags).message =~ "telemetry"
  end

  test "allows facade with telemetry.span" do
    facade = parse("""
      defmodule MyApp.Accounts do
        def create_user(attrs) do
          :telemetry.span([:my_app, :accounts, :create_user], %{}, fn ->
            {:ok, %{}}
          end)
        end
        def get_user(id), do: nil
      end
    """, "lib/my_app/accounts.ex")

    sub = parse("""
      defmodule MyApp.Accounts.User do
        defstruct [:id]
      end
    """, "lib/my_app/accounts/user.ex")

    diags = MissingTelemetry.analyze_project([facade, sub])
    assert diags == []
  end

  test "skips modules with fewer than 2 public functions" do
    facade = parse("""
      defmodule MyApp.Tiny do
        def only_one, do: :ok
      end
    """, "lib/my_app/tiny.ex")

    sub = parse("""
      defmodule MyApp.Tiny.Helper do
        def help, do: :ok
      end
    """, "lib/my_app/tiny/helper.ex")

    diags = MissingTelemetry.analyze_project([facade, sub])
    assert diags == []
  end

  test "skips non-facade modules (no matching directory)" do
    standalone = parse("""
      defmodule MyApp.Utils do
        def helper_a, do: :ok
        def helper_b, do: :ok
        def helper_c, do: :ok
      end
    """, "lib/my_app/utils.ex")

    diags = MissingTelemetry.analyze_project([standalone])
    assert diags == []
  end
end
