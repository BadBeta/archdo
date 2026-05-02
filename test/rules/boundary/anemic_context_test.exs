defmodule Archdo.Rules.Boundary.AnemicContextTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Boundary.AnemicContext

  describe "analyze_project/1" do
    test "flags context directory with only 1 file" do
      files = ["/project/lib/my_app/payments/stripe.ex"]

      diags = AnemicContext.analyze_project(files)
      assert diags != []
      assert hd(diags).rule_id == "1.11"
    end

    test "allows context with 3+ files" do
      files = [
        "/project/lib/my_app/accounts/user.ex",
        "/project/lib/my_app/accounts/credential.ex",
        "/project/lib/my_app/accounts/auth.ex"
      ]

      diags = AnemicContext.analyze_project(files)
      assert diags == []
    end
  end
end
