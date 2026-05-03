defmodule Archdo.Rules.Module.DuplicatedValidationTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.DuplicatedValidation

  defp parse(file, code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {file, ast}
  end

  describe "analyze_project/1" do
    test "flags a validation that appears in both web and domain layers" do
      file_asts = [
        # Domain — schema layer detected by `use Ecto.Schema`
        parse("lib/my_app/accounts/user.ex", ~S"""
        defmodule MyApp.Accounts.User do
          use Ecto.Schema

          def validate_email(changeset) do
            changeset
          end
        end
        """),
        # Web — controller detected by `use Phoenix.Controller`
        parse("lib/my_app_web/controllers/user_controller.ex", ~S"""
        defmodule MyAppWeb.UserController do
          use Phoenix.Controller

          defp validate_email(params) do
            params
          end
        end
        """)
      ]

      diags = DuplicatedValidation.analyze_project(file_asts)

      assert [diag] = diags
      assert diag.rule_id == "3.6"
      assert diag.context.validation == "validate_email"
    end

    test "does NOT flag when the validation is only in the domain" do
      file_asts = [
        parse("lib/my_app/accounts/user.ex", ~S"""
        defmodule MyApp.Accounts.User do
          use Ecto.Schema

          def validate_email(cs), do: cs
        end
        """),
        parse("lib/my_app_web/controllers/user_controller.ex", ~S"""
        defmodule MyAppWeb.UserController do
          use Phoenix.Controller

          def index(conn, _), do: conn
        end
        """)
      ]

      assert DuplicatedValidation.analyze_project(file_asts) == []
    end

    test "does NOT flag when the validation is only in the web layer" do
      file_asts = [
        parse("lib/my_app/accounts/user.ex", ~S"""
        defmodule MyApp.Accounts.User do
          use Ecto.Schema
          def normalize(cs), do: cs
        end
        """),
        parse("lib/my_app_web/controllers/user_controller.ex", ~S"""
        defmodule MyAppWeb.UserController do
          use Phoenix.Controller
          defp validate_email(p), do: p
        end
        """)
      ]

      assert DuplicatedValidation.analyze_project(file_asts) == []
    end

    test "ignores test files entirely" do
      file_asts = [
        parse("lib/my_app/accounts/user.ex", ~S"""
        defmodule MyApp.Accounts.User do
          use Ecto.Schema
          def validate_email(cs), do: cs
        end
        """),
        parse("test/my_app_web/user_controller_test.exs", ~S"""
        defmodule MyAppWeb.UserControllerTest do
          use ExUnit.Case
          defp validate_email(p), do: p
        end
        """)
      ]

      assert DuplicatedValidation.analyze_project(file_asts) == []
    end

    test "ignores functions whose name doesn't start with validate_" do
      file_asts = [
        parse("lib/my_app/accounts/user.ex", ~S"""
        defmodule MyApp.Accounts.User do
          use Ecto.Schema
          def check_email(cs), do: cs
        end
        """),
        parse("lib/my_app_web/controllers/user_controller.ex", ~S"""
        defmodule MyAppWeb.UserController do
          use Phoenix.Controller
          def check_email(p), do: p
        end
        """)
      ]

      assert DuplicatedValidation.analyze_project(file_asts) == []
    end

    test "flags multiple distinct duplicated validations" do
      file_asts = [
        parse("lib/my_app/accounts/user.ex", ~S"""
        defmodule MyApp.Accounts.User do
          use Ecto.Schema
          def validate_email(cs), do: cs
          def validate_age(cs), do: cs
        end
        """),
        parse("lib/my_app_web/controllers/user_controller.ex", ~S"""
        defmodule MyAppWeb.UserController do
          use Phoenix.Controller
          defp validate_email(p), do: p
          defp validate_age(p), do: p
        end
        """)
      ]

      names =
        DuplicatedValidation.analyze_project(file_asts)
        |> Enum.map(& &1.context.validation)
        |> Enum.sort()

      assert names == ["validate_age", "validate_email"]
    end
  end
end
