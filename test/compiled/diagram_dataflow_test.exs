defmodule Archdo.Compiled.DiagramDataflowTest do
  use ExUnit.Case, async: true

  alias Archdo.Compiled.Diagram

  defp data(overrides) do
    %{
      ctx_id: "MyApp_Accounts",
      ctx_name: "MyApp.Accounts",
      boundary: nil,
      internal: [],
      external_callers: [],
      external_deps: [],
      internal_wiring: []
    }
    |> Map.merge(overrides)
  end

  describe "format_dataflow_context/1 — header + subgraph" do
    test "always emits graph LR header and the context subgraph" do
      out = Diagram.format_dataflow_context(data(%{}))
      assert out =~ "graph LR"
      assert out =~ ~s(subgraph MyApp_Accounts["MyApp.Accounts"])
      assert out =~ "  end"
    end
  end

  describe "format_dataflow_context/1 — boundary module rendering" do
    test "boundary nil emits no boundary node and no boundary style" do
      out = Diagram.format_dataflow_context(data(%{boundary: nil}))
      refute out =~ "BOUNDARY"
      refute out =~ "fill:#4CAF50"
    end

    test "boundary module emits a hex-decorated node and a green style" do
      out = Diagram.format_dataflow_context(data(%{boundary: MyApp.Accounts}))
      assert out =~ ~s(MyApp_Accounts{{"Accounts · BOUNDARY"}})
      assert out =~ "style MyApp_Accounts fill:#4CAF50"
    end
  end

  describe "format_dataflow_context/1 — internal modules" do
    test "renders up to 12 internal modules as boxes" do
      mods = Enum.map(1..3, fn i -> Module.concat(MyApp.Accounts, :"M#{i}") end)
      out = Diagram.format_dataflow_context(data(%{internal: mods}))
      assert out =~ ~s(MyApp_Accounts_M1["M1"])
      assert out =~ ~s(MyApp_Accounts_M2["M2"])
      assert out =~ ~s(MyApp_Accounts_M3["M3"])
      refute out =~ "more_MyApp_Accounts"
    end

    test "caps at 12 internal modules and shows overflow line" do
      mods = Enum.map(1..15, fn i -> Module.concat(MyApp.Accounts, :"M#{i}") end)
      out = Diagram.format_dataflow_context(data(%{internal: mods}))
      assert out =~ ~s(more_MyApp_Accounts["... +3 more"])
    end

    test "no overflow when count is exactly at the cap" do
      mods = Enum.map(1..12, fn i -> Module.concat(MyApp.Accounts, :"M#{i}") end)
      out = Diagram.format_dataflow_context(data(%{internal: mods}))
      refute out =~ "more_MyApp_Accounts"
    end
  end

  describe "format_dataflow_context/1 — external callers and deps" do
    test "external caller groups produce blue input-terminal styles" do
      # call shape: {caller, callee, fns_called, call_count} where fns_called
      # is a list of {atom, arity} tuples.
      callers = [
        {MyApp.Web, [{MyApp.Web, MyApp.Accounts.User, [{:create, 1}], 3}]}
      ]

      out = Diagram.format_dataflow_context(data(%{external_callers: callers}))
      assert out =~ "style MyApp_Web fill:#BBDEFB"
    end

    test "external dep groups produce orange output-terminal styles" do
      deps = [
        {MyApp.Repo, [{MyApp.Accounts.User, MyApp.Repo, [{:insert, 1}], 5}]}
      ]

      out = Diagram.format_dataflow_context(data(%{external_deps: deps}))
      assert out =~ "style MyApp_Repo fill:#FFE0B2"
    end
  end

  describe "format_dataflow_context/1 — internal wiring passthrough" do
    test "internal_wiring lines are emitted verbatim" do
      out =
        Diagram.format_dataflow_context(
          data(%{internal_wiring: ["  MyApp_A --> MyApp_B", "  MyApp_B --> MyApp_C"]})
        )

      assert out =~ "  MyApp_A --> MyApp_B"
      assert out =~ "  MyApp_B --> MyApp_C"
    end
  end
end
