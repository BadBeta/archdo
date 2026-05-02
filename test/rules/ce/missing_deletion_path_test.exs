defmodule Archdo.Rules.CE.MissingDeletionPathTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.MissingDeletionPath

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

  describe "CE-53 — PII schema lacks right-to-deletion path" do
    test "fires on PII schema without any delete_for_/forget_/anonymize_/erase_ function" do
      file_asts = [
        parse("lib/myapp/user.ex", ~S"""
        defmodule MyApp.User do
          use Ecto.Schema

          schema "users" do
            field :email, :string
            field :phone, :string
          end
        end
        """)
      ]

      diags = MissingDeletionPath.analyze_project(file_asts, gdpr_scope: true)
      assert [diag] = diags
      assert diag.rule_id == "CE-53"
      assert diag.message =~ "MyApp.User"
    end

    test "does NOT fire when delete_for_user/1 references the schema" do
      file_asts = [
        parse("lib/myapp/user.ex", ~S"""
        defmodule MyApp.User do
          use Ecto.Schema

          schema "users" do
            field :email, :string
          end
        end
        """),
        parse("lib/myapp/accounts.ex", ~S"""
        defmodule MyApp.Accounts do
          alias MyApp.User

          def delete_for_user(user_id) do
            from(u in User, where: u.id == ^user_id) |> MyApp.Repo.delete_all()
          end
        end
        """)
      ]

      assert MissingDeletionPath.analyze_project(file_asts, gdpr_scope: true) == []
    end

    test "does NOT fire when anonymize_user/1 references the schema" do
      file_asts = [
        parse("lib/myapp/user.ex", ~S"""
        defmodule MyApp.User do
          use Ecto.Schema

          schema "users" do
            field :email, :string
          end
        end
        """),
        parse("lib/myapp/accounts.ex", ~S"""
        defmodule MyApp.Accounts do
          def anonymize_user(user) do
            %MyApp.User{user | email: "anonymized@example.com"} |> MyApp.Repo.update!()
          end
        end
        """)
      ]

      assert MissingDeletionPath.analyze_project(file_asts, gdpr_scope: true) == []
    end

    test "does NOT fire when forget_user/1 references the schema" do
      file_asts = [
        parse("lib/myapp/user.ex", ~S"""
        defmodule MyApp.User do
          use Ecto.Schema

          schema "users" do
            field :email, :string
          end
        end
        """),
        parse("lib/myapp/accounts.ex", ~S"""
        defmodule MyApp.Accounts do
          def forget_user(id) do
            user = MyApp.Repo.get!(MyApp.User, id)
            MyApp.Repo.delete!(user)
          end
        end
        """)
      ]

      assert MissingDeletionPath.analyze_project(file_asts, gdpr_scope: true) == []
    end

    test "does NOT fire when gdpr_scope is not enabled (off by default)" do
      file_asts = [
        parse("lib/myapp/user.ex", ~S"""
        defmodule MyApp.User do
          use Ecto.Schema

          schema "users" do
            field :email, :string
          end
        end
        """)
      ]

      assert MissingDeletionPath.analyze_project(file_asts) == []
    end

    test "does NOT fire on schema without PII fields (not in CE-51 set)" do
      file_asts = [
        parse("lib/myapp/preference.ex", ~S"""
        defmodule MyApp.Preference do
          use Ecto.Schema

          schema "preferences" do
            field :theme, :string
          end
        end
        """)
      ]

      assert MissingDeletionPath.analyze_project(file_asts, gdpr_scope: true) == []
    end

    test "does NOT fire when @archdo_gdpr_exempt marker is set" do
      file_asts = [
        parse("lib/myapp/employee.ex", ~S"""
        defmodule MyApp.Employee do
          use Ecto.Schema
          @archdo_gdpr_exempt "employee data under separate legal basis"

          schema "employees" do
            field :email, :string
          end
        end
        """)
      ]

      assert MissingDeletionPath.analyze_project(file_asts, gdpr_scope: true) == []
    end
  end

  describe "pack assignment" do
    test "rule pack is :ce_privacy (opt-in)" do
      assert MissingDeletionPath.pack() == :ce_privacy
    end
  end
end
