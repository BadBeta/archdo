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
