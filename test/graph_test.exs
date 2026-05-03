defmodule Archdo.GraphTest do
  use ExUnit.Case, async: true

  alias Archdo.Graph

  describe "edge_of_type?/2" do
    test "true when edge.type matches the given kind" do
      edge = %{source: "A", target: "B", type: :call, file: "a.ex", line: 1}
      assert Graph.edge_of_type?(edge, :call)
    end

    test "false when edge.type doesn't match" do
      edge = %{source: "A", target: "B", type: :call, file: "a.ex", line: 1}
      refute Graph.edge_of_type?(edge, :alias)
    end

    test "matches across all known dep types" do
      for type <- [:call, :alias, :import, :use, :registry] do
        edge = %{source: "A", target: "B", type: type, file: "a.ex", line: 1}
        assert Graph.edge_of_type?(edge, type)
      end
    end
  end
end
