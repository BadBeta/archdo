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

  # `update` is a CLI convention (rustup self update, gh extension
  # upgrade, fly version update). For escripts, the underlying
  # operation is `mix escript.install --force <source>` — atomic
  # replace, no separate uninstall step needed. Archdo has no
  # user-home state, so re-running --force preserves all project-
  # local config (`.archdo.exs`, `.archdo_baseline.exs`, `.mcp.json`)
  # automatically.
  defp dispatch(["update" | rest]), do: run_update(rest)

  defp dispatch(argv), do: Mix.Tasks.Archdo.run(argv)

  @doc false
  # Pure: maps the argv tail after `update` to a source spec.
  # Exposed (with @doc false) so the precedence and shape are
  # unit-testable without invoking the mix subprocess.
  @spec parse_update_args([String.t()]) ::
          {:ok, :default | {:hex, String.t()} | {:github, String.t()} | {:git, String.t()}}
          | {:error, String.t()}
  def parse_update_args([]), do: {:ok, :default}
  def parse_update_args(["--source", "hex", pkg]), do: {:ok, {:hex, pkg}}
  def parse_update_args(["--source", "github", spec]), do: {:ok, {:github, spec}}
  def parse_update_args(["--source", "git", url]), do: {:ok, {:git, url}}

  def parse_update_args(["--source", kind | _]),
    do: {:error, "unknown source kind: #{inspect(kind)} (expected hex | github | git)"}

  def parse_update_args(other),
    do: {:error, "unrecognised update arguments: #{inspect(other)}"}

  @doc false
  # Pure: builds the {executable, args} pair that `archdo update`
  # will hand to System.cmd/3. Tested independently so we don't have
  # to actually run mix in the test suite.
  @spec build_update_command(
          :default | {:hex, String.t()} | {:github, String.t()} | {:git, String.t()}
        ) :: {String.t(), [String.t()]}
  def build_update_command(:default), do: build_update_command({:github, "BadBeta/archdo"})

  def build_update_command({:hex, pkg}),
    do: {"mix", ["escript.install", "--force", "hex", pkg]}

  def build_update_command({:github, spec}),
    do: {"mix", ["escript.install", "--force", "github", spec]}

  def build_update_command({:git, url}),
    do: {"mix", ["escript.install", "--force", "git", url]}

  defp run_update(rest) do
    case parse_update_args(rest) do
      {:ok, source} ->
        do_run_update(build_update_command(source))

      {:error, message} ->
        IO.puts(:stderr, "archdo update: #{message}")
        IO.puts(:stderr, "")
        IO.puts(:stderr, "Usage:")
        IO.puts(:stderr, "  archdo update                              # github BadBeta/archdo (default)")
        IO.puts(:stderr, "  archdo update --source hex archdo")
        IO.puts(:stderr, "  archdo update --source github OWNER/REPO")
        IO.puts(:stderr, "  archdo update --source git URL")
        System.halt(2)
    end
  end

  defp do_run_update({cmd, args}) do
    IO.puts("Updating archdo: #{cmd} #{Enum.join(args, " ")}")
    IO.puts("Persistent settings (`.archdo.exs`, `.archdo_baseline.exs`, `.mcp.json`)")
    IO.puts("are project-local and will not be touched by this update.")
    IO.puts("")

    case System.cmd(cmd, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("")
        IO.puts("✓ archdo updated")
        :ok

      {_, code} ->
        IO.puts(:stderr, "")
        IO.puts(:stderr, "✗ update failed (exit #{code})")
        System.halt(code)
    end
  end

  # Baked in at compile time. `Mix.Project.config/0` is not available
  # at escript runtime — escripts strip the Mix project context. The
  # version is embedded into the BEAM at build time instead.
  @version Mix.Project.config()[:version] || "unknown"

  defp print_version do
    IO.puts("archdo #{@version}")
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

    Subcommands:
      archdo update                              Re-install archdo from github BadBeta/archdo (atomic --force)
      archdo update --source hex archdo          Re-install from Hex
      archdo update --source github OWNER/REPO   Re-install from a different GitHub source
      archdo update --source git URL             Re-install from an arbitrary git repository

    Examples:
      archdo                                          # check ./lib with default rules
      archdo --paths /other/project/lib --format text # analyse another project
      archdo --packs core,ce_privacy --paths lib      # opt into a pack
      archdo --explain 6.50                           # what does rule 6.50 mean?
      archdo --since main --format compact            # PR review
      archdo update                                   # update to the latest github main branch

    Full reference:
      GUIDE.md             https://github.com/BadBeta/archdo/blob/main/GUIDE.md
      ARCHITECTURE_RULES.md  per-rule reference
    """
  end
end
