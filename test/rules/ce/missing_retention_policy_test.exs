defmodule Archdo.Rules.CE.MissingRetentionPolicyTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.MissingRetentionPolicy

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

  describe "CE-52 — schema with user data lacks retention policy" do
    test "fires on user-data schema with timestamps but no cleanup or annotation" do
      file_asts = [
        parse("lib/myapp/sessions.ex", ~S"""
        defmodule MyApp.Sessions.Session do
          use Ecto.Schema

          schema "sessions" do
            field :token, :string
            belongs_to :user, MyApp.Accounts.User
            timestamps()
          end
        end
        """)
      ]

      diags = MissingRetentionPolicy.analyze_project(file_asts)
      assert [diag] = diags
      assert diag.rule_id == "CE-52"
      assert diag.message =~ "sessions"
    end

    test "does NOT fire when @retention is set" do
      file_asts = [
        parse("lib/myapp/audit_log.ex", ~S"""
        defmodule MyApp.Audit.Log do
          use Ecto.Schema
          @retention "forever — required for compliance"

          schema "audit_logs" do
            field :event, :string
            belongs_to :user, MyApp.Accounts.User
            timestamps()
          end
        end
        """)
      ]

      assert MissingRetentionPolicy.analyze_project(file_asts) == []
    end

    test "does NOT fire when an Oban worker references the table" do
      file_asts = [
        parse("lib/myapp/sessions/session.ex", ~S"""
        defmodule MyApp.Sessions.Session do
          use Ecto.Schema

          schema "sessions" do
            field :token, :string
            belongs_to :user, MyApp.Accounts.User
            timestamps()
          end
        end
        """),
        parse("lib/myapp/workers/session_cleaner.ex", ~S"""
        defmodule MyApp.Workers.SessionCleaner do
          use Oban.Worker, queue: :cleanup

          @impl Oban.Worker
          def perform(_job) do
            from(s in "sessions", where: s.inserted_at < ago(30, "day"))
            |> MyApp.Repo.delete_all()
          end
        end
        """)
      ]

      assert MissingRetentionPolicy.analyze_project(file_asts) == []
    end

    test "does NOT fire on schema with no user FK (not user data)" do
      file_asts = [
        parse("lib/myapp/system_config.ex", ~S"""
        defmodule MyApp.SystemConfig do
          use Ecto.Schema

          schema "system_configs" do
            field :key, :string
            field :value, :string
            timestamps()
          end
        end
        """)
      ]

      assert MissingRetentionPolicy.analyze_project(file_asts) == []
    end

    test "does NOT fire on non-schema modules" do
      file_asts = [
        parse("lib/myapp/util.ex", ~S"""
        defmodule MyApp.Util do
          def go(x), do: x
        end
        """)
      ]

      assert MissingRetentionPolicy.analyze_project(file_asts) == []
    end

    test "does NOT fire on schema without timestamps (no growth signal)" do
      file_asts = [
        parse("lib/myapp/preference.ex", ~S"""
        defmodule MyApp.Preference do
          use Ecto.Schema

          schema "preferences" do
            field :theme, :string
            belongs_to :user, MyApp.Accounts.User
          end
        end
        """)
      ]

      assert MissingRetentionPolicy.analyze_project(file_asts) == []
    end

    test "fires on configurable user-like FK names (member, account, owner)" do
      file_asts = [
        parse("lib/myapp/account_session.ex", ~S"""
        defmodule MyApp.AccountSession do
          use Ecto.Schema

          schema "account_sessions" do
            field :token, :string
            belongs_to :account, MyApp.Account
            timestamps()
          end
        end
        """)
      ]

      diags = MissingRetentionPolicy.analyze_project(file_asts)
      assert [diag] = diags
      assert diag.rule_id == "CE-52"
    end
  end

  describe "pack assignment" do
    test "rule pack is :ce_privacy (opt-in)" do
      assert MissingRetentionPolicy.pack() == :ce_privacy
    end
  end
end
