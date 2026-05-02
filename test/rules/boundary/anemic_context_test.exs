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

    test "respects configured min_files threshold from .archdo.exs" do
      # 4 files — over default of 3, so clean WITHOUT a config
      files = [
        "/project/lib/my_app/accounts/user.ex",
        "/project/lib/my_app/accounts/credential.ex",
        "/project/lib/my_app/accounts/auth.ex",
        "/project/lib/my_app/accounts/session.ex"
      ]

      assert AnemicContext.analyze_project(files) == []

      # With min_files bumped to 5, 4 files now fires
      config =
        Archdo.Config.from_keyword(
          [thresholds: [{"1.11", min_files: 5}]],
          "/tmp/test_root"
        )

      diags_configured = AnemicContext.analyze_project(files, config: config)

      assert [diag] = diags_configured
      assert diag.rule_id == "1.11"
    end
  end
end
