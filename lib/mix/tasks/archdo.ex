defmodule Mix.Tasks.Archdo do
  @dialyzer :no_undefined_callbacks
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
    * `--compiled` - Enable analysis using compiled beam files. Adds dead
      code detection, macro-aware behaviour checking, and precise call graph.
      Requires the target project to be compiled (`mix compile`).
    * `--coverage` - Print test coverage gap matrix and exit (no other rules run)
    * `--metrics` - Print Martin package metrics (Ca/Ce/I/A/D) matrix and exit
    * `--diagram` - Generate Mermaid architecture diagram from compiled beams.
      Values: `overview` (contexts + cross-boundary deps), `modules` (all module deps),
      `api` (public API surface per context), `blast:Module.Name` (blast radius for a module),
      `context:Context.Name` (detail view of one context), `delta` (AST vs compiled diff —
      shows hidden macro-injected deps and phantom unused deps), `delta-only` (only the
      differences). Requires compiled beams.

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
          compiled: :boolean,
          coverage: :boolean,
          diagram: :string,
          metrics: :boolean,
          freeze: :boolean,
          freeze_stats: :boolean,
          show_all: :boolean
        ]
      )

    paths = parse_list(Keyword.get(opts, :paths, "lib"))

    cond do
      Keyword.has_key?(opts, :diagram) ->
        run_diagram(opts[:diagram], paths)
        :ok

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
      Keyword.put(build_run_opts(opts), :show_all, Keyword.get(opts, :show_all, false))

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
    compiled = Keyword.get(opts, :compiled, false)

    maybe_add([format: format, ignore: ignore, boundaries: boundaries, tests: tests, functions: functions, compiled: compiled], :only, only)
  end

  defp run_diagram(diagram_type, paths) do
    project_root =
      case paths do
        [path | _] ->
          path
          |> Path.expand()
          |> find_project_root()

        _ ->
          File.cwd!()
      end

    case Archdo.Compiled.analyze(project_root) do
      {:ok, graph} ->
        mermaid = generate_diagram(graph, diagram_type)
        IO.puts(mermaid)

      {:error, reason} ->
        IO.puts(:standard_error, "[archdo] diagram: #{reason}")
    end
  end

  defp generate_diagram(graph, "overview"), do: Archdo.Compiled.Diagram.architecture_overview(graph)
  defp generate_diagram(graph, "modules"), do: Archdo.Compiled.Diagram.module_dependencies(graph)
  defp generate_diagram(graph, "api"), do: Archdo.Compiled.Diagram.api_surface(graph)
  defp generate_diagram(graph, "delta"), do: Archdo.Compiled.Diagram.dependency_delta(graph, ["lib"])
  defp generate_diagram(graph, "delta-only"), do: Archdo.Compiled.Diagram.dependency_delta_only(graph, ["lib"])

  defp generate_diagram(graph, "dataflow:" <> module_name) do
    mod = String.to_atom("Elixir.#{module_name}")
    Archdo.Compiled.Diagram.dataflow_module(graph, mod)
  end

  defp generate_diagram(graph, "dataflow-context:" <> context_name) do
    Archdo.Compiled.Diagram.dataflow_context(graph, context_name)
  end

  # SVG variants — proper port-based LabVIEW/Grasshopper-style diagrams
  defp generate_diagram(graph, "svg:" <> module_name) do
    mod = String.to_atom("Elixir.#{module_name}")
    Archdo.Compiled.DiagramSVG.module_dataflow(graph, mod)
  end

  defp generate_diagram(graph, "svg-context:" <> context_name) do
    Archdo.Compiled.DiagramSVG.context_dataflow(graph, context_name)
  end

  # OTP diagrams
  defp generate_diagram(graph, "otp") do
    Archdo.Compiled.DiagramOTP.supervision_diagram(graph)
  end

  defp generate_diagram(graph, "otp-messages") do
    Archdo.Compiled.DiagramOTP.messaging_diagram(graph)
  end

  defp generate_diagram(graph, "system") do
    Archdo.Compiled.DiagramSystem.system_diagram(graph)
  end

  defp generate_diagram(graph, "blast:" <> module_name) do
    mod = String.to_atom("Elixir.#{module_name}")
    Archdo.Compiled.Diagram.blast_radius(graph, mod)
  end

  defp generate_diagram(graph, "context:" <> context_name) do
    Archdo.Compiled.Diagram.context_detail(graph, context_name)
  end

  defp generate_diagram(_graph, other) do
    "graph LR\n  error[\"Unknown diagram type: #{other}<br/>Use: overview, modules, api, blast:Module, context:Name\"]"
  end

  defp find_project_root(path) do
    cond do
      File.exists?(Path.join(path, "mix.exs")) -> path
      path == "/" -> File.cwd!()
      true -> find_project_root(Path.dirname(path))
    end
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
  defp parse_format(other), do: raise("Unknown format: #{other}")

  defp parse_list(str), do: String.split(str, ",", trim: true)

  defp parse_nullable_list(nil), do: nil
  defp parse_nullable_list(str), do: parse_list(str)

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
