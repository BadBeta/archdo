defmodule Archdo.Rules.EventSourcing.ProjectorReadsExternalTest do
  use Archdo.RuleCase

  alias Archdo.Rules.EventSourcing.ProjectorReadsExternal

  describe "analyze/3" do
    test "flags DateTime.utc_now in projector" do
      code = ~S"""
      defmodule MyApp.Projectors.AccountProjector do
        use Commanded.Projections.Ecto, name: "AccountProjector"

        project(%AccountCreated{} = event, _meta, fn multi ->
          now = DateTime.utc_now()
          Ecto.Multi.insert(multi, :account, %Account{id: event.id, projected_at: now})
        end)
      end
      """

      diags = assert_flagged(ProjectorReadsExternal, code)
      assert hd(diags).rule_id == "8.6"
      assert hd(diags).message =~ "DateTime.utc_now"
    end

    test "allows projector without non-deterministic calls" do
      code = ~S"""
      defmodule MyApp.Projectors.AccountProjector do
        use Commanded.Projections.Ecto, name: "AccountProjector"

        project(%AccountCreated{} = event, _meta, fn multi ->
          Ecto.Multi.insert(multi, :account, %Account{id: event.id, name: event.name})
        end)
      end
      """

      assert_clean(ProjectorReadsExternal, code)
    end

    test "ignores non-projector modules" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def now, do: DateTime.utc_now()
      end
      """

      assert_clean(ProjectorReadsExternal, code)
    end
  end
end
