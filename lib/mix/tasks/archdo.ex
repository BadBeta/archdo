defmodule Mix.Tasks.Archdo do
  @shortdoc "Run architectural quality checks"
  @moduledoc """
  Runs Archdo architectural quality checks against the project.

      mix archdo [options]

  ## Options

    * `--format` - Output format: `text` (default), `json`, `compact`, `llm`
    * `--only` - Comma-separated rule IDs to check (e.g., `--only 5.11,5.12`)
    * `--ignore` - Comma-separated rule IDs to skip
    * `--paths` - Comma-separated paths to check (default: `lib`)
    * `--boundaries` - Enable boundary analysis (Phase 2: dependency direction,
      context encapsulation, circular deps). Uses `.archdo.exs` config or
      Phoenix conventions for layer detection.
    * `--tests` - Enable project-level test architecture checks (e.g., missing test files)
    * `--functions` - Enable function-level graph analysis (slowest, deepest)
    * `--coverage` - Print test coverage gap matrix and exit (no other rules run)
    * `--metrics` - Print Martin package metrics (Ca/Ce/I/A/D) matrix and exit

  ## Baseline / Freeze

  When adopting Archdo on an existing codebase, you probably have hundreds of
  existing violations. Use freeze to accept them as a starting baseline and
  only flag NEW violations going forward:

    * `--freeze` - Save current violations as a baseline (`.archdo_baseline.exs`)
    * `--freeze-stats` - Show baseline status (resolved, still present, new)
    * `--show-all` - Bypass baseline and show all violations

  Workflow:

      $ mix archdo --freeze          # capture current state
      $ git add .archdo_baseline.exs
      $ mix archdo                   # only new violations shown
      $ mix archdo --freeze-stats    # see what's been fixed

  ## Exit codes

    * `0` — no new violations
    * `1` — warnings found
    * `2` — errors found
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          format: :string,
          only: :string,
          ignore: :string,
          paths: :string,
          boundaries: :boolean,
          tests: :boolean,
          functions: :boolean,
          coverage: :boolean,
          metrics: :boolean,
          freeze: :boolean,
          freeze_stats: :boolean,
          show_all: :boolean
        ]
      )

    paths = parse_list(Keyword.get(opts, :paths, "lib"))

    cond do
      Keyword.get(opts, :coverage, false) ->
        Archdo.print_coverage_matrix(paths)
        :ok

      Keyword.get(opts, :metrics, false) ->
        Archdo.print_metrics_matrix(paths)
        :ok

      Keyword.get(opts, :freeze, false) ->
        run_opts = build_run_opts(opts)
        Archdo.freeze_baseline(paths, run_opts)
        :ok

      Keyword.get(opts, :freeze_stats, false) ->
        run_opts = build_run_opts(opts)
        exit_status = Archdo.freeze_stats(paths, run_opts)
        maybe_exit(exit_status)

      true ->
        run_normal(opts, paths)
    end
  end

  defp run_normal(opts, paths) do
    run_opts =
      build_run_opts(opts)
      |> Keyword.put(:show_all, Keyword.get(opts, :show_all, false))

    exit_status = Archdo.run_and_format(paths, run_opts)
    maybe_exit(exit_status)
  end

  defp build_run_opts(opts) do
    format = parse_format(Keyword.get(opts, :format, "text"))
    only = parse_nullable_list(Keyword.get(opts, :only))
    ignore = parse_nullable_list(Keyword.get(opts, :ignore)) || []
    boundaries = Keyword.get(opts, :boundaries, false)
    tests = Keyword.get(opts, :tests, false)
    functions = Keyword.get(opts, :functions, false)

    [format: format, ignore: ignore, boundaries: boundaries, tests: tests, functions: functions]
    |> maybe_add(:only, only)
  end

  defp maybe_exit(exit_status) do
    if exit_status > 0 do
      System.at_exit(fn _ -> exit({:shutdown, exit_status}) end)
    end
  end

  defp parse_format("text"), do: :text
  defp parse_format("json"), do: :json
  defp parse_format("compact"), do: :compact
  defp parse_format("llm"), do: :llm
  defp parse_format(other), do: Mix.raise("Unknown format: #{other}")

  defp parse_list(str), do: String.split(str, ",", trim: true)

  defp parse_nullable_list(nil), do: nil
  defp parse_nullable_list(str), do: parse_list(str)

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
