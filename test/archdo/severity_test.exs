defmodule Archdo.SeverityTest do
  use ExUnit.Case, async: true

  alias Archdo.Severity

  defp classification(layer), do: %{layer: layer}

  describe "adjust/3 — test layer" do
    test "downgrades quality :warning to :info in test files" do
      assert Severity.adjust("6.2", :warning, classification(:test)) == :info
      assert Severity.adjust("3.4", :warning, classification(:test)) == :info
      assert Severity.adjust("6.46", :warning, classification(:test)) == :info
    end

    test "preserves :error severity even in test files (real bugs are real)" do
      assert Severity.adjust("8.3", :error, classification(:test)) == :error
    end

    test "leaves :info as :info" do
      assert Severity.adjust("6.33", :info, classification(:test)) == :info
    end
  end

  describe "adjust/3 — :other layer (scripts, ad-hoc files)" do
    test "downgrades :warning to :info" do
      assert Severity.adjust("6.2", :warning, classification(:other)) == :info
    end

    test "preserves :error" do
      assert Severity.adjust("8.3", :error, classification(:other)) == :error
    end
  end

  describe "adjust/3 — production layers" do
    test "leaves :warning untouched in :context layer" do
      assert Severity.adjust("6.2", :warning, classification(:context)) == :warning
    end

    test "leaves :warning untouched in :live_view layer" do
      assert Severity.adjust("4.18", :warning, classification(:live_view)) == :warning
    end

    test "leaves :warning untouched in :web layer" do
      assert Severity.adjust("1.26", :warning, classification(:web)) == :warning
    end
  end

  describe "adjust/3 — operational/application_root" do
    test "downgrades :warning to :info in operational (rules should already filter)" do
      assert Severity.adjust("4.4", :warning, classification(:operational)) == :info
    end

    test "downgrades :warning to :info in application_root" do
      assert Severity.adjust("1.26", :warning, classification(:application_root)) == :info
    end
  end

  describe "adjust/3 — graceful inputs" do
    test "accepts nil classification (treats as production)" do
      assert Severity.adjust("6.2", :warning, nil) == :warning
    end

    test "accepts missing layer key (treats as production)" do
      assert Severity.adjust("6.2", :warning, %{}) == :warning
    end
  end

  describe "adjust_diagnostic/2" do
    test "rewrites severity in a Diagnostic struct" do
      diag = %Archdo.Diagnostic{
        rule_id: "6.2",
        severity: :warning,
        title: "x",
        message: "x",
        why: "x",
        file: "test/foo_test.exs",
        line: 1
      }

      adjusted = Severity.adjust_diagnostic(diag, classification(:test))
      assert adjusted.severity == :info
    end

    test "leaves Diagnostic untouched when classification preserves severity" do
      diag = %Archdo.Diagnostic{
        rule_id: "6.2",
        severity: :warning,
        title: "x",
        message: "x",
        why: "x",
        file: "lib/my_app/foo.ex",
        line: 1
      }

      adjusted = Severity.adjust_diagnostic(diag, classification(:context))
      assert adjusted.severity == :warning
    end
  end
end
