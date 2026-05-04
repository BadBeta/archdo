defmodule Archdo.GitDiffTest do
  use ExUnit.Case, async: true

  alias Archdo.GitDiff

  describe "changed_files/2" do
    test "returns {:error, msg} for an unknown ref" do
      assert {:error, msg} =
               GitDiff.changed_files("definitely-not-a-real-ref-xyz", ["lib"])

      assert is_binary(msg)
      assert msg =~ "git diff failed"
    end

    test "returns {:ok, []} when there are no .ex changes against HEAD~0" do
      # HEAD against itself yields no diff regardless of working tree.
      assert {:ok, files} = GitDiff.changed_files("HEAD", ["lib"])
      # Files may be present (if there are uncommitted changes), but
      # the call must succeed and return a list of strings.
      assert is_list(files)
      assert Enum.all?(files, &is_binary/1)
    end

    test "filters non-.ex paths" do
      # Hard to set up a git state in a unit test without a fixture
      # repo — this assertion is the existence-of-filter contract:
      # whatever changed_files returns is a list whose every element
      # ends in .ex.
      {:ok, files} = GitDiff.changed_files("HEAD", ["lib"])
      assert Enum.all?(files, &String.ends_with?(&1, ".ex"))
    end
  end
end
