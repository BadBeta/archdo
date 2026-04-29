defmodule Archdo.Rules.Boundary.SharedDbTableTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Boundary.SharedDbTable

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

  describe "analyze_project/1" do
    test "flags schema for the same table in two contexts" do
      site_schema =
        parse(
          """
          defmodule MyApp.Site.Tracker do
            use Ecto.Schema
            schema "trackers" do
              field :name, :string
            end
          end
          """,
          "lib/my_app/site/tracker.ex"
        )

      audit_schema =
        parse(
          """
          defmodule MyApp.Audit.Tracker do
            use Ecto.Schema
            schema "trackers" do
              field :name, :string
            end
          end
          """,
          "lib/my_app/audit/tracker.ex"
        )

      diags = SharedDbTable.analyze_project([site_schema, audit_schema])
      assert length(diags) == 2
      assert Enum.all?(diags, &(&1.rule_id == "1.31"))
    end

    test "does not flag operational data_migration schemas as a separate context" do
      # Plausible: lib/plausible/data_migration/backfill_*.ex defines a
      # local schema for a backfill — same table as the real owning
      # context, but operational code, not a separate ownership claim.
      real_schema =
        parse(
          """
          defmodule MyApp.Site.Tracker do
            use Ecto.Schema
            schema "trackers" do
              field :name, :string
            end
          end
          """,
          "lib/my_app/site/tracker.ex"
        )

      backfill_schema =
        parse(
          """
          defmodule MyApp.DataMigration.BackfillTracker do
            use Ecto.Schema
            schema "trackers" do
              field :name, :string
            end
          end
          """,
          "lib/my_app/data_migration/backfill_tracker.ex"
        )

      assert SharedDbTable.analyze_project([real_schema, backfill_schema]) == []
    end

    test "does not flag schemas defined in Mix tasks" do
      real_schema =
        parse(
          """
          defmodule MyApp.Accounts.User do
            use Ecto.Schema
            schema "users" do
              field :email, :string
            end
          end
          """,
          "lib/my_app/accounts/user.ex"
        )

      mix_task_schema =
        parse(
          """
          defmodule Mix.Tasks.MyApp.Backfill do
            use Mix.Task
            use Ecto.Schema
            schema "users" do
              field :email, :string
            end
          end
          """,
          "lib/mix/tasks/my_app.backfill.ex"
        )

      assert SharedDbTable.analyze_project([real_schema, mix_task_schema]) == []
    end
  end
end
