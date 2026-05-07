defmodule Archdo.CLI do
  @moduledoc """
  Escript entry point — lets `archdo` be installed and run as a
  standalone CLI without `mix` and without adding the package to a
  target project's `mix.exs`.

  Build: `mix escript.build` produces `./archdo`.
  Install globally: `mix escript.install hex archdo` (or `github
  BadBeta/archdo`) — places the executable under `~/.mix/escripts/`.
  Run: `archdo --paths lib --format text` from any project root.

  This module is a thin wrapper. All option parsing, dispatch, and
  output handling live in `Mix.Tasks.Archdo` — the escript and the
  Mix task share the same code path so behaviour is identical.
  """

  @doc """
  Escript entry point. Receives raw argv and returns the same value
  the underlying Mix task returns (typically `:ok`). Some commands
  call `System.halt/1` via `Mix.Task` to set the exit code; that's
  intentional and matches the Mix task's behaviour.
  """
  @spec main([String.t()]) :: :ok | term()
  def main(argv) when is_list(argv) do
    # `:logger` is needed by some rules (and Mix). Started defensively
    # in case the escript bundling didn't auto-start it.
    _ = Application.ensure_all_started(:logger)
    dispatch(argv)
  end

  # `--help` / `-h` are CLI conventions, not Mix-task conventions. The
  # Mix task delegates to `mix help archdo`; the escript handles the
  # flag directly so users running `archdo --help` get usage without
  # needing Mix.
  defp dispatch(argv) when argv in [["--help"], ["-h"], ["help"]] do
    IO.puts(usage())
    :ok
  end

  defp dispatch(["--version"]), do: print_version()
  defp dispatch(["-v"]), do: print_version()

  defp dispatch(argv), do: Mix.Tasks.Archdo.run(argv)

  defp print_version do
    version = Mix.Project.config()[:version] || "unknown"
    IO.puts("archdo #{version}")
    :ok
  end

  defp usage do
    """
    archdo — architectural quality checker for Elixir

    Usage:
      archdo [options]

    Common options:
      --paths PATHS              Paths to scan (comma-separated, default: lib)
      --format FMT               summary | text | compact | json | llm | sarif | html
      --packs PACKS              Comma-separated optional packs:
                                 core | ce_compliance | ce_privacy | ce_composability
      --only RULES               Restrict to these rule ids
      --ignore RULES             Skip these rule ids
      --since REF                Only analyse files changed since git ref
      --explain RULE             Print rule documentation and exit
      --list-packs               List rule packs and exit
      --building-blocks          Print modules passing the Blackbox audit
      --metrics                  Print Martin Ca/Ce/I/A/D matrix
      --coverage                 Print test coverage gap matrix
      --diagram TYPE             Generate Mermaid/SVG architecture diagram
      --boundaries / --no-boundaries
      --functions  / --no-functions
      --tests                    Enable project-level test architecture rules
      --compiled                 Read BEAM artefacts (requires `mix compile` in target)
      --freeze / --freeze-stats / --show-all
      --fix [--dry-run]          Auto-apply mechanical fixes
      --watch                    Re-run on file changes
      --version, -v              Print version and exit
      --help, -h                 Show this message

    Examples:
      archdo                                          # check ./lib with default rules
      archdo --paths /other/project/lib --format text # analyse another project
      archdo --packs core,ce_privacy --paths lib      # opt into a pack
      archdo --explain 6.50                           # what does rule 6.50 mean?
      archdo --since main --format compact            # PR review

    Full reference:
      GUIDE.md             https://github.com/BadBeta/archdo/blob/main/GUIDE.md
      ARCHITECTURE_RULES.md  per-rule reference
    """
  end
end
