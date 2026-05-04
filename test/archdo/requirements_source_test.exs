defmodule Archdo.RequirementsSourceTest do
  use ExUnit.Case, async: true

  alias Archdo.RequirementsSource

  @moduletag :tmp_dir

  defp write_json(tmp_dir, name, json) do
    path = Path.join(tmp_dir, name)
    File.write!(path, json)
    path
  end

  describe "load/1" do
    test "loads a flat list of string IDs", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, "reqs.json", ~S(["REQ-1", "REQ-2"]))
      assert {:ok, entries} = RequirementsSource.load(path)
      assert entries == [%{id: "REQ-1", status: nil}, %{id: "REQ-2", status: nil}]
    end

    test "loads a list of objects with id+status", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, "reqs.json", ~S([
          {"id": "REQ-1", "status": "active"},
          {"id": "REQ-2", "status": "cancelled"}
        ]))

      assert {:ok, entries} = RequirementsSource.load(path)
      assert %{id: "REQ-1", status: "active"} in entries
      assert %{id: "REQ-2", status: "cancelled"} in entries
    end

    test "skips malformed list entries", %{tmp_dir: tmp_dir} do
      path =
        write_json(tmp_dir, "reqs.json", ~S(["REQ-1", 42, {"no_id": true}]))

      assert {:ok, entries} = RequirementsSource.load(path)
      assert entries == [%{id: "REQ-1", status: nil}]
    end

    test "returns {:error, :enoent} for a missing file", %{tmp_dir: tmp_dir} do
      assert {:error, :enoent} =
               RequirementsSource.load(Path.join(tmp_dir, "missing.json"))
    end

    test "returns {:error, _} for malformed JSON", %{tmp_dir: tmp_dir} do
      path = write_json(tmp_dir, "broken.json", "this is not json")
      assert {:error, _} = RequirementsSource.load(path)
    end
  end

  describe "actionable/1" do
    test "filters out cancelled / deferred / out_of_scope statuses" do
      entries = [
        %{id: "A", status: "active"},
        %{id: "B", status: "cancelled"},
        %{id: "C", status: "deferred"},
        %{id: "D", status: "out_of_scope"},
        %{id: "E", status: "not_in_scope"},
        %{id: "F", status: nil}
      ]

      result = RequirementsSource.actionable(entries)
      assert Enum.map(result, & &1.id) == ["A", "F"]
    end
  end

  describe "actionable_ids/1" do
    test "returns a MapSet of IDs after status filtering" do
      entries = [
        %{id: "A", status: "active"},
        %{id: "B", status: "cancelled"},
        %{id: "C", status: nil}
      ]

      assert MapSet.equal?(
               RequirementsSource.actionable_ids(entries),
               MapSet.new(["A", "C"])
             )
    end
  end
end
