defmodule Archdo.DiagnosticTest do
  use ExUnit.Case, async: true

  alias Archdo.Diagnostic

  @required title: "t",
            message: "m",
            why: "w",
            file: "lib/foo.ex",
            line: 1

  describe "error/2 / warning/2 / info/2 / nitpick/2" do
    test "build a diagnostic with the given severity and rule id" do
      d = Diagnostic.error("1.1", @required)
      assert d.severity == :error
      assert d.rule_id == "1.1"
      assert d.title == "t"
    end

    test "warning has :warning severity" do
      assert %{severity: :warning} = Diagnostic.warning("1.2", @required)
    end

    test "info has :info severity" do
      assert %{severity: :info} = Diagnostic.info("1.3", @required)
    end

    test "nitpick has :nitpick severity" do
      assert %{severity: :nitpick} = Diagnostic.nitpick("1.4", @required)
    end

    test "passes through optional fields (alternatives, references, context, tags)" do
      d =
        Diagnostic.warning(
          "1.5",
          @required ++
            [
              alternatives: [Archdo.Fix.new(summary: "s", detail: "d", applies_when: "a")],
              references: ["docs.md#section"],
              context: %{key: "value"},
              tags: [:passed]
            ]
        )

      assert [%Archdo.Fix{}] = d.alternatives
      assert d.references == ["docs.md#section"]
      assert d.context == %{key: "value"}
      assert d.tags == [:passed]
    end

    test "default optional fields are empty collections" do
      d = Diagnostic.info("1.6", @required)
      assert d.alternatives == []
      assert d.references == []
      assert d.context == %{}
      assert d.tags == []
    end
  end

  describe "builder_for/1" do
    test "returns the matching constructor function" do
      assert is_function(Diagnostic.builder_for(:error), 2)
      assert is_function(Diagnostic.builder_for(:warning), 2)
      assert is_function(Diagnostic.builder_for(:info), 2)
      assert is_function(Diagnostic.builder_for(:nitpick), 2)
    end

    test "the returned function builds a diagnostic of the requested severity" do
      builder = Diagnostic.builder_for(:warning)
      assert %{severity: :warning} = builder.("9.9", @required)
    end
  end

  describe "severity_order/1" do
    test "orders error < warning < info < nitpick" do
      assert Diagnostic.severity_order(:error) == 0
      assert Diagnostic.severity_order(:warning) == 1
      assert Diagnostic.severity_order(:info) == 2
      assert Diagnostic.severity_order(:nitpick) == 3
    end
  end

  describe "new/1" do
    test "builds a diagnostic from a keyword list" do
      d = Diagnostic.new([{:rule_id, "1.7"}, {:severity, :info} | @required])
      assert d.severity == :info
      assert d.rule_id == "1.7"
    end

    test "raises on missing required keys" do
      assert_raise ArgumentError, fn -> Diagnostic.new([]) end
    end
  end

  describe ":confidence field" do
    test "defaults to :high when not supplied" do
      assert %{confidence: :high} = Diagnostic.error("1.8", @required)
      assert %{confidence: :high} = Diagnostic.warning("1.8", @required)
      assert %{confidence: :high} = Diagnostic.info("1.8", @required)
      assert %{confidence: :high} = Diagnostic.nitpick("1.8", @required)
    end

    test "preserves an explicit :medium" do
      d = Diagnostic.warning("1.9", @required ++ [confidence: :medium])
      assert d.confidence == :medium
    end

    test "preserves an explicit :low" do
      d = Diagnostic.info("1.10", @required ++ [confidence: :low])
      assert d.confidence == :low
    end

    test "with_confidence/2 sets the field on an existing diagnostic" do
      d = Diagnostic.error("1.11", @required)
      assert %{confidence: :medium} = Diagnostic.with_confidence(d, :medium)
      assert %{confidence: :low} = Diagnostic.with_confidence(d, :low)
      assert %{confidence: :high} = Diagnostic.with_confidence(d, :high)
    end
  end
end
