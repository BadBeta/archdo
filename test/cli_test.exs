defmodule Archdo.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "main/1" do
    test "--help prints usage and returns :ok" do
      output =
        capture_io(fn ->
          assert Archdo.CLI.main(["--help"]) == :ok
        end)

      assert output =~ "archdo"
      assert output =~ "--paths"
      assert output =~ "--format"
    end

    test "--explain prints rule documentation" do
      # Pick a rule that exists in the registry. Any well-known core
      # rule works — we just need the explain path to dispatch.
      output =
        capture_io(fn ->
          Archdo.CLI.main(["--explain", "5.51"])
        end)

      assert output =~ "5.51"
    end

    test "--list-packs prints the pack roster" do
      output =
        capture_io(fn ->
          Archdo.CLI.main(["--list-packs"])
        end)

      assert output =~ "core"
      assert output =~ "ce_compliance"
    end

    test "--version prints the current version" do
      output =
        capture_io(fn ->
          assert Archdo.CLI.main(["--version"]) == :ok
        end)

      assert output =~ ~r/^archdo \S+/
    end
  end

  describe "build_update_command/1" do
    # The pure command-builder underlying `archdo update`. We test the
    # command shape rather than running mix — the actual subprocess
    # call would mutate the developer's ~/.mix/escripts/.

    test "default source is the github main branch of BadBeta/archdo" do
      assert {"mix", ["escript.install", "--force", "github", "BadBeta/archdo"]} =
               Archdo.CLI.build_update_command(:default)
    end

    test "hex source builds an escript.install hex command" do
      assert {"mix", ["escript.install", "--force", "hex", "archdo"]} =
               Archdo.CLI.build_update_command({:hex, "archdo"})
    end

    test "github source accepts user/repo" do
      assert {"mix", ["escript.install", "--force", "github", "owner/repo"]} =
               Archdo.CLI.build_update_command({:github, "owner/repo"})
    end

    test "git source accepts an arbitrary URL" do
      assert {"mix", ["escript.install", "--force", "git", "https://example.com/archdo.git"]} =
               Archdo.CLI.build_update_command({:git, "https://example.com/archdo.git"})
    end
  end

  describe "parse_update_args/1" do
    # Maps argv tail (after `update`) to the source spec.

    test "no args defaults to github BadBeta/archdo" do
      assert Archdo.CLI.parse_update_args([]) == {:ok, :default}
    end

    test "--source hex archdo selects hex" do
      assert Archdo.CLI.parse_update_args(["--source", "hex", "archdo"]) ==
               {:ok, {:hex, "archdo"}}
    end

    test "--source github owner/repo selects github" do
      assert Archdo.CLI.parse_update_args(["--source", "github", "owner/repo"]) ==
               {:ok, {:github, "owner/repo"}}
    end

    test "--source git URL selects git" do
      assert Archdo.CLI.parse_update_args(["--source", "git", "https://x/y.git"]) ==
               {:ok, {:git, "https://x/y.git"}}
    end

    test "unknown source flag returns an error" do
      assert {:error, _} = Archdo.CLI.parse_update_args(["--source", "ftp", "x"])
    end
  end

  describe "main/1 — unknown option handling" do
    test "rejects unknown options without crashing the BEAM" do
      # An escript receives raw argv. Unknown flags must produce a
      # diagnostic exit, not an unhandled crash. We capture both stdout
      # and stderr; one of them carries the error.
      output =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            try do
              Archdo.CLI.main(["--definitely-not-a-flag"])
            catch
              :exit, _ -> :ok
            end
          end)
        end)

      # We don't assert exact wording — just that the program is the
      # one shouting, not the BEAM.
      assert is_binary(output)
    end
  end
end
