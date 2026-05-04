defmodule Archdo.McpTest do
  use ExUnit.Case, async: true

  describe "Archdo.Mcp facade" do
    test "exports run/0 (delegated to Server)" do
      Code.ensure_loaded(Archdo.Mcp)
      assert function_exported?(Archdo.Mcp, :run, 0)
    end

    test "moduledoc documents the facade nature" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Archdo.Mcp)
      assert doc =~ "MCP"
    end
  end
end
