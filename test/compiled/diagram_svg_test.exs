defmodule Archdo.Compiled.DiagramSVGRenderTest do
  use ExUnit.Case, async: true

  alias Archdo.Compiled.DiagramSVG

  describe "column_width/2" do
    test "empty list yields zero (no column rendered)" do
      assert 0 = DiagramSVG.column_width([], 200)
    end

    test "non-empty list yields the configured width" do
      assert 200 = DiagramSVG.column_width([:something], 200)
    end

    test "non-empty regardless of element shape" do
      assert 99 = DiagramSVG.column_width([%{module: MyApp.A}, %{module: MyApp.B}], 99)
    end
  end

  describe "member_style/2" do
    test "boundary module gets dark-green bg, green border, [BOUNDARY] suffix" do
      {bg, border, label} = DiagramSVG.member_style(true, MyApp.Accounts)
      assert bg == "#2D4F3D"
      assert border == "#4CAF50"
      assert label == "Accounts [BOUNDARY]"
    end

    test "non-boundary module gets the default node bg/border and a plain label" do
      {_bg, _border, label} = DiagramSVG.member_style(false, MyApp.Accounts.User)
      assert label == "User"
      # bg/border come from module attrs — assert the boundary highlights
      # are NOT present so a future swap of the defaults still trips this.
      refute match?({"#2D4F3D", _, _}, DiagramSVG.member_style(false, MyApp.Accounts.User))
      refute match?({_, "#4CAF50", _}, DiagramSVG.member_style(false, MyApp.Accounts.User))
    end
  end
end
