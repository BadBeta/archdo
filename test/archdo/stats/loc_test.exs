defmodule Archdo.Stats.LocTest do
  use ExUnit.Case, async: true

  alias Archdo.Stats.Loc

  describe "analyze_content/1 — line classification" do
    test "blank lines counted separately from physical, comments separately from code" do
      # 18 lines total: 5 blanks, 3 comments, 10 code lines.
      content = """
      # c1
      # c2

      def f1, do: 1


      def f2, do: 2
      def f3, do: 3
      def f4, do: 4
      def f5, do: 5

      def f6, do: 6
      def f7, do: 7
      def f8, do: 8

      # c3
      def f9, do: 9
      def f10, do: 10\
      """

      result = Loc.analyze_content(content)

      assert result.physical == 18
      assert result.blanks == 5
      assert result.comments == 3
    end

    test "logical excludes do/end and comments — single 6-line def is one logical expression" do
      # Six physical lines, one top-level def → logical = 1.
      content = """
      def f(x) do
        y = x + 1
        z = y * 2

        z + x
      end\
      """

      result = Loc.analyze_content(content)

      assert result.physical == 6
      assert result.logical == 1
    end

    test "shebang line at line 1 counts as physical, not as a comment" do
      content = """
      #!/usr/bin/env elixir
      defmodule M do
        def f, do: 1
      end\
      """

      result = Loc.analyze_content(content)

      assert result.physical == 4
      assert result.comments == 0
    end

    test "comments inside string literals don't count as comments" do
      # The `#` is inside a "..." string — the line is code, not a comment.
      content = ~S(def f, do: "# not a comment")

      result = Loc.analyze_content(content)

      assert result.physical == 1
      assert result.comments == 0
    end
  end
end
