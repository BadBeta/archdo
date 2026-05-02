defmodule Archdo.Rules.CE.PiiFieldHandlingTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.PiiFieldHandling

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

  describe "CE-51 — PII field without designated handling" do
    test "fires on schema with :email field and no Inspect derivation" do
      file_asts = [
        parse("lib/myapp/user.ex", ~S"""
        defmodule MyApp.User do
          use Ecto.Schema

          schema "users" do
            field :name, :string
            field :email, :string
            field :phone, :string
          end
        end
        """)
      ]

      diags = PiiFieldHandling.analyze_project(file_asts)
      assert [diag] = diags
      assert diag.rule_id == "CE-51"
      assert diag.message =~ "MyApp.User"
      assert diag.message =~ "email" or diag.message =~ "phone"
    end

    test "does NOT fire when @derive {Inspect, except: [...]} excludes the PII fields" do
      file_asts = [
        parse("lib/myapp/user.ex", ~S"""
        defmodule MyApp.User do
          use Ecto.Schema
          @derive {Inspect, except: [:email, :phone, :password_hash]}

          schema "users" do
            field :name, :string
            field :email, :string
            field :phone, :string
            field :password_hash, :string
          end
        end
        """)
      ]

      assert PiiFieldHandling.analyze_project(file_asts) == []
    end

    test "fires when @derive Inspect except list misses some PII fields" do
      file_asts = [
        parse("lib/myapp/user.ex", ~S"""
        defmodule MyApp.User do
          use Ecto.Schema
          @derive {Inspect, except: [:password_hash]}

          schema "users" do
            field :name, :string
            field :email, :string
            field :password_hash, :string
          end
        end
        """)
      ]

      diags = PiiFieldHandling.analyze_project(file_asts)
      assert [diag] = diags
      assert diag.message =~ "email"
      refute diag.message =~ "password_hash"
    end

    test "does NOT fire on schema with no PII fields" do
      file_asts = [
        parse("lib/myapp/preference.ex", ~S"""
        defmodule MyApp.Preference do
          use Ecto.Schema

          schema "preferences" do
            field :theme, :string
            field :language, :string
          end
        end
        """)
      ]

      assert PiiFieldHandling.analyze_project(file_asts) == []
    end

    test "does NOT fire on non-schema modules" do
      file_asts = [
        parse("lib/myapp/util.ex", ~S"""
        defmodule MyApp.Util do
          def go(x), do: x
        end
        """)
      ]

      assert PiiFieldHandling.analyze_project(file_asts) == []
    end

    test "matches *_token, password*, *_id PII patterns" do
      file_asts = [
        parse("lib/myapp/session.ex", ~S"""
        defmodule MyApp.Session do
          use Ecto.Schema

          schema "sessions" do
            field :api_token, :string
            field :session_token, :string
          end
        end
        """)
      ]

      diags = PiiFieldHandling.analyze_project(file_asts)
      assert [diag] = diags
      assert diag.rule_id == "CE-51"
    end

    test "does NOT fire when @archdo_pii_handled marker is set" do
      file_asts = [
        parse("lib/myapp/special.ex", ~S"""
        defmodule MyApp.Special do
          use Ecto.Schema
          @archdo_pii_handled "fields are intentionally public — display profile"

          schema "profiles" do
            field :email, :string
          end
        end
        """)
      ]

      assert PiiFieldHandling.analyze_project(file_asts) == []
    end

    test "lists the unprotected PII fields in the message" do
      file_asts = [
        parse("lib/myapp/user.ex", ~S"""
        defmodule MyApp.User do
          use Ecto.Schema

          schema "users" do
            field :name, :string
            field :email, :string
            field :ssn, :string
            field :date_of_birth, :date
          end
        end
        """)
      ]

      [diag] = PiiFieldHandling.analyze_project(file_asts)
      assert diag.message =~ "email"
      assert diag.message =~ "ssn"
      assert diag.message =~ "date_of_birth"
    end
  end

  describe "pack assignment" do
    test "rule pack is :ce_privacy (opt-in)" do
      assert PiiFieldHandling.pack() == :ce_privacy
    end
  end
end
