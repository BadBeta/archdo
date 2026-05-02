defmodule Archdo.Rules.Boundary.GodContextTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Boundary.GodContext

  describe "analyze_project/1" do
    test "flags context directory with >20 files" do
      files =
        Enum.map(1..25, fn i ->
          "/project/lib/my_app/accounts/user_#{i}.ex"
        end)

      diags = GodContext.analyze_project(files)
      assert diags != []
      assert hd(diags).rule_id == "4.7"
    end

    test "allows context with few files" do
      files = [
        "/project/lib/my_app/accounts/user.ex",
        "/project/lib/my_app/accounts/credential.ex",
        "/project/lib/my_app/accounts/auth.ex"
      ]

      diags = GodContext.analyze_project(files)
      assert diags == []
    end
  end
end
