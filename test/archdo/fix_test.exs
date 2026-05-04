defmodule Archdo.FixTest do
  use ExUnit.Case, async: true

  alias Archdo.Fix

  describe "new/1" do
    test "builds a Fix from a keyword list" do
      fix = Fix.new(summary: "s", detail: "d")
      assert %Fix{summary: "s", detail: "d", example: nil, applies_when: nil} = fix
    end

    test "passes through optional fields" do
      fix = Fix.new(summary: "s", detail: "d", example: "code", applies_when: "X applies")
      assert fix.example == "code"
      assert fix.applies_when == "X applies"
    end

    test "raises when required summary or detail is missing" do
      assert_raise ArgumentError, fn -> Fix.new(summary: "s") end
      assert_raise ArgumentError, fn -> Fix.new(detail: "d") end
    end
  end

  describe "to_map/1" do
    test "converts a Fix struct to a plain map" do
      fix = Fix.new(summary: "s", detail: "d", example: "ex", applies_when: "aw")

      assert Fix.to_map(fix) == %{
               summary: "s",
               detail: "d",
               example: "ex",
               applies_when: "aw"
             }
    end

    test "preserves nil for optional fields" do
      fix = Fix.new(summary: "s", detail: "d")
      m = Fix.to_map(fix)
      assert m.example == nil
      assert m.applies_when == nil
    end
  end
end
