defmodule Archdo.Rules.Module.MixedConcernsTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.MixedConcerns

  describe "analyze/3" do
    test "flags module mixing web and persistence and HTTP" do
      code = ~S"""
      defmodule MyApp.GodModule do
        import Ecto.Query
        alias MyApp.Repo

        def index(conn, _params) do
          users = Repo.all(User)
          resp = Req.get!("https://api.example.com/enrich")
          Phoenix.Controller.json(conn, users)
        end
      end
      """

      diags = assert_flagged(MixedConcerns, code)
      assert hd(diags).rule_id == "4.13"
    end

    test "allows module with single concern" do
      code = ~S"""
      defmodule MyApp.Accounts do
        import Ecto.Query
        alias MyApp.Repo

        def list_users do
          Repo.all(User)
        end
      end
      """

      assert_clean(MixedConcerns, code)
    end
  end
end
