defmodule Mix.Tasks.Archdo do
  @dialyzer :no_undefined_callbacks
  @shortdoc "Run architectural quality checks"
  @moduledoc """
  Runs Archdo architectural quality checks against the project.

      mix archdo [options]

  ## Options

    * `--format` - Output format: `summary` (default), `text`, `brief`, `json`, `compact`, `llm`, `sarif`, `html`
    * `--only` - Comma-separated rule IDs to check (e.g., `--only 5.11,5.12`)
    * `--ignore` - Comma-separated rule IDs to skip
    * `--packs` - Comma-separated optional packs to enable. `:core` is always
      implied; declare additional packs to opt in. Known packs:
      `core`, `ce_compliance`, `ce_privacy`, `ce_composability`.
    * `--list-packs` - Print the pack roster (which rules belong to each pack)
      and exit.
    * `--building-blocks` - Print modules and contexts that pass the Blackbox
      audit (every public function scores ≥ 0.9). Tells you what's safely
      reusable / memoizable / extractable as-is.
    * `--paths` - Comma-separated paths to check (default: `lib`)
    * `--since` - Only analyze files changed since this git ref (e.g., `--since main`)
    * `--explain` - Explain a rule by ID (e.g., `--explain 6.50`)
    * `--init` - Generate a `.archdo.exs` config file with detected project defaults
    * `--fix` - [EXPERIMENTAL] Auto-apply mechanical fixes. Use `--fix --dry-run` to preview first.
    * `--boundaries` - Cross-file boundary/graph rules (default: true). Disable with `--no-boundaries`.
    * `--tests` - Project-level test architecture checks (default: false).
    * `--functions` - Function-level graph analysis (default: true). Disable with `--no-functions`.
    * `--compiled` - Enable analysis using compiled beam files. Adds dead
      code detection, macro-aware behaviour checking, and precise call graph.
      Requires the target project to be compiled (`mix compile`).
    * `--coverage` - Print test coverage gap matrix and exit (no other rules run)
    * `--stats` - Print project statistics (files, lines, modules, functions, tests, OTP constructs) and exit
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

  alias Archdo.{AST, Compare, Compiled, Formatter, Rule, Runner, Stats}

  alias Archdo.Compiled.{
    Diagram,
    DiagramInteractive,
    DiagramOTP,
    DiagramSVG,
    DiagramSystem
  }

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          format: :string,
          only: :string,
          ignore: :string,
          packs: :string,
          list_packs: :boolean,
          paths: :string,
          since: :string,
          explain: :string,
          init: :boolean,
          fix: :boolean,
          dry_run: :boolean,
          boundaries: :boolean,
          tests: :boolean,
          functions: :boolean,
          compiled: :boolean,
          coverage: :boolean,
          diagram: :string,
          stats: :boolean,
          metrics: :boolean,
          building_blocks: :boolean,
          freeze: :boolean,
          freeze_stats: :boolean,
          show_all: :boolean,
          watch: :boolean,
          gdpr_scope: :boolean,
          traceability_required_paths: :string,
          requirements_source: :string,
          compare_with: :string
        ]
      )

    paths = parse_list(Keyword.get(opts, :paths, "lib"))

    cond do
      Keyword.has_key?(opts, :explain) ->
        run_explain(opts[:explain])

      Keyword.get(opts, :init, false) ->
        run_init()

      Keyword.has_key?(opts, :diagram) ->
        run_diagram(opts[:diagram], paths)
        :ok

      Keyword.get(opts, :stats, false) ->
        stats = Stats.collect(paths)
        Mix.shell().info(Stats.format(stats))
        :ok

      Keyword.get(opts, :list_packs, false) ->
        run_list_packs()
        :ok

      Keyword.get(opts, :coverage, false) ->
        Archdo.print_coverage_matrix(paths)
        :ok

      Keyword.get(opts, :metrics, false) ->
        Archdo.print_metrics_matrix(paths)
        :ok

      Keyword.get(opts, :building_blocks, false) ->
        Archdo.print_building_blocks(paths)
        :ok

      Keyword.has_key?(opts, :compare_with) ->
        run_compare(opts, paths)
        :ok

      Keyword.get(opts, :freeze, false) ->
        run_opts = build_run_opts(opts)
        Archdo.freeze_baseline(paths, run_opts)
        :ok

      Keyword.get(opts, :freeze_stats, false) ->
        run_opts = build_run_opts(opts)
        exit_status = Archdo.freeze_stats(paths, run_opts)
        maybe_exit(exit_status)

      Keyword.has_key?(opts, :since) ->
        run_since(opts, paths)

      Keyword.get(opts, :fix, false) ->
        run_fix(opts, paths)

      Keyword.get(opts, :watch, false) ->
        run_watch(opts, paths)

      true ->
        run_normal(opts, paths)
    end
  end

  defp run_compare(opts, paths) do
    compare_paths = parse_list(Keyword.get(opts, :compare_with, ""))
    run_opts = build_run_opts(opts)

    paths
    |> Compare.run(compare_paths, run_opts)
    |> Compare.merge()
    |> Compare.format()
    |> Mix.shell().info()
  end

  defp run_normal(opts, paths) do
    run_opts =
      Keyword.put(build_run_opts(opts), :show_all, Keyword.get(opts, :show_all, false))

    exit_status = Archdo.run_and_format(paths, run_opts)
    maybe_exit(exit_status)
  end

  defp build_run_opts(opts) do
    format = parse_format(Keyword.get(opts, :format, "summary"))
    only = parse_nullable_list(Keyword.get(opts, :only))
    ignore = parse_nullable_list(Keyword.get(opts, :ignore)) || []
    packs = parse_packs(Keyword.get(opts, :packs))
    boundaries = Keyword.get(opts, :boundaries, true)
    tests = Keyword.get(opts, :tests, false)
    functions = Keyword.get(opts, :functions, true)
    compiled = Keyword.get(opts, :compiled, false)

    [
      format: format,
      ignore: ignore,
      packs: packs,
      boundaries: boundaries,
      tests: tests,
      functions: functions,
      compiled: compiled,
      gdpr_scope: Keyword.get(opts, :gdpr_scope, false),
      traceability_required_paths:
        parse_nullable_list(Keyword.get(opts, :traceability_required_paths)) || [],
      requirements_source: Keyword.get(opts, :requirements_source)
    ]
    |> maybe_add(:only, only)
  end

  # §§ elixir-planning: §6 — Pack abstraction (M13). CLI parses
  # `--packs core,ce_composability` into a list of atoms. Validates against
  # `Rule.known_packs/0` so a typo (e.g. `--packs ce_composabilty`)
  # crashes at parse time with a useful message rather than silently
  # excluding every rule.
  defp run_list_packs do
    rules =
      Runner.phase1_rules() ++
        Runner.graph_rules() ++
        Archdo.project_rules()

    by_pack = Enum.group_by(rules, &Rule.pack_of/1)

    Mix.shell().info("Archdo packs:\n")

    for pack <- Rule.known_packs() do
      members = Map.get(by_pack, pack, [])
      Mix.shell().info("  #{pack} (#{length(members)} rules)")

      members
      |> Enum.sort_by(& &1.id())
      |> Enum.each(fn rule ->
        Mix.shell().info("    #{rule.id()} — #{rule.description()}")
      end)

      Mix.shell().info("")
    end
  end

  defp parse_packs(nil), do: [:core]

  defp parse_packs(str) when is_binary(str) do
    known = Rule.known_packs()

    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn name ->
      atom = String.to_existing_atom(name)

      case atom in known do
        true ->
          atom

        false ->
          Mix.raise(
            "Unknown pack: #{inspect(atom)}. Known packs: #{inspect(known)}"
          )
      end
    end)
  rescue
    ArgumentError ->
      Mix.raise(
        "Unknown pack name in --packs #{inspect(str)}. Known packs: #{inspect(Rule.known_packs())}"
      )
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

    case Compiled.analyze(project_root) do
      {:ok, graph} ->
        case diagram_type do
          "interactive" ->
            html = DiagramInteractive.generate(graph)
            File.write!("archdo_interactive.html", html)
            IO.puts("Interactive diagram written to archdo_interactive.html")
            System.cmd("xdg-open", ["archdo_interactive.html"], stderr_to_stdout: true)

          _ ->
            mermaid = generate_diagram(graph, diagram_type)
            IO.puts(mermaid)
        end

      {:error, reason} ->
        IO.puts(:standard_error, "[archdo] diagram: #{reason}")
    end
  end

  defp generate_diagram(graph, "overview"),
    do: Diagram.architecture_overview(graph)

  defp generate_diagram(graph, "modules"), do: Diagram.module_dependencies(graph)
  defp generate_diagram(graph, "api"), do: Diagram.api_surface(graph)

  defp generate_diagram(graph, "delta"),
    do: Diagram.dependency_delta(graph, ["lib"])

  defp generate_diagram(graph, "delta-only"),
    do: Diagram.dependency_delta_only(graph, ["lib"])

  defp generate_diagram(graph, "dataflow:" <> module_name) do
    mod = String.to_atom("Elixir.#{module_name}")
    Diagram.dataflow_module(graph, mod)
  end

  defp generate_diagram(graph, "dataflow-context:" <> context_name) do
    Diagram.dataflow_context(graph, context_name)
  end

  # SVG variants — proper port-based LabVIEW/Grasshopper-style diagrams
  defp generate_diagram(graph, "svg:" <> module_name) do
    mod = String.to_atom("Elixir.#{module_name}")
    DiagramSVG.module_dataflow(graph, mod)
  end

  defp generate_diagram(graph, "svg-context:" <> context_name) do
    DiagramSVG.context_dataflow(graph, context_name)
  end

  # OTP diagrams
  defp generate_diagram(graph, "otp") do
    DiagramOTP.supervision_diagram(graph)
  end

  defp generate_diagram(graph, "otp-messages") do
    DiagramOTP.messaging_diagram(graph)
  end

  defp generate_diagram(graph, "system") do
    DiagramSystem.system_diagram(graph)
  end

  defp generate_diagram(graph, "blast:" <> module_name) do
    mod = String.to_atom("Elixir.#{module_name}")
    Diagram.blast_radius(graph, mod)
  end

  defp generate_diagram(graph, "context:" <> context_name) do
    Diagram.context_detail(graph, context_name)
  end

  defp generate_diagram(_graph, other) do
    "graph LR\n  error[\"Unknown diagram type: #{other}<br/>Use: overview, modules, api, blast:Module, context:Name\"]"
  end

  # --- --explain ---

  defp run_explain(rule_id) do
    rules = Runner.phase1_rules() ++ Runner.graph_rules()

    case Enum.find(rules, fn r -> r.id() == rule_id end) do
      nil ->
        IO.puts("Unknown rule: #{rule_id}")
        IO.puts("Use `mix archdo --explain` with a valid rule ID (e.g., 6.50)")

      rule ->
        IO.puts("\nRule #{rule.id()} — #{rule.description()}\n")
        IO.puts("Module: #{inspect(rule)}")
        IO.puts("Category: #{category_for(rule_id)}")
    end
  end

  defp category_for("1." <> _), do: "Boundaries"
  defp category_for("2." <> _), do: "Public API"
  defp category_for("3." <> _), do: "Single Source of Truth"
  defp category_for("4." <> _), do: "Coupling & Abstraction"
  defp category_for("5." <> _), do: "OTP Process Architecture"
  defp category_for("6." <> _), do: "Module Quality"
  defp category_for("7." <> _), do: "Test Architecture"
  defp category_for("8." <> _), do: "Event Sourcing"
  defp category_for("9." <> _), do: "State Machine"
  defp category_for("10." <> _), do: "Composition"
  defp category_for("11." <> _), do: "Native Interop"
  defp category_for(_), do: "Other"

  # --- --init ---

  defp run_init do
    case File.exists?(".archdo.exs") do
      true ->
        IO.puts(".archdo.exs already exists. Delete it first to regenerate.")

      false ->
        project_type = detect_project_type()
        config = generate_config(project_type)
        File.write!(".archdo.exs", config)
        IO.puts("Created .archdo.exs (detected: #{project_type})")
        IO.puts("Edit the file to customize layers, contexts, and severity overrides.")
    end
  end

  defp detect_project_type do
    cond do
      File.exists?("apps") and File.dir?("apps") -> :umbrella
      File.exists?("lib") and has_phoenix_dep?() -> :phoenix
      File.exists?("lib") -> :library
      true -> :unknown
    end
  end

  defp has_phoenix_dep? do
    case File.read("mix.exs") do
      {:ok, content} -> String.contains?(content, ":phoenix")
      _ -> false
    end
  end

  defp generate_config(:phoenix) do
    app_name = detect_app_name()

    """
    # Archdo configuration — generated for Phoenix project
    [
      # Layer definitions
      layers: [
        interface: ~r/^#{app_name}Web\\./,
        domain: ~r/^#{app_name}\\.(?!Repo|Mailer)/,
        infrastructure: ~r/^#{app_name}\\.(Repo|Mailer)/
      ],

      # Allowed dependency direction (interface → domain → infrastructure)
      allowed_deps: %{
        interface: [:domain, :infrastructure],
        domain: [:infrastructure],
        infrastructure: []
      },

      # Severity overrides (uncomment to customize)
      # overrides: [
      #   {:"5.6", :ignore},           # Accept default supervisor restarts
      #   {:"6.4", severity: :info},    # Downgrade long files to info
      # ]
    ]
    """
  end

  defp generate_config(:umbrella) do
    """
    # Archdo configuration — generated for umbrella project
    [
      # Run from each child app: cd apps/my_app && mix archdo
      # Or from root: mix archdo --paths apps/my_app/lib

      # Severity overrides (uncomment to customize)
      # overrides: [
      #   {:"5.6", :ignore},
      # ]
    ]
    """
  end

  defp generate_config(_) do
    """
    # Archdo configuration
    [
      # Severity overrides (uncomment to customize)
      # overrides: [
      #   {:"5.6", :ignore},           # Accept default supervisor restarts
      #   {:"6.4", severity: :info},    # Downgrade long files to info
      # ]
    ]
    """
  end

  defp detect_app_name do
    case File.read("mix.exs") do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> Macro.camelize(name)
          _ -> "MyApp"
        end

      _ ->
        "MyApp"
    end
  end

  # --- --since ---

  defp run_since(opts, base_paths) do
    ref = Keyword.fetch!(opts, :since)

    case changed_files_since(ref, base_paths) do
      {:ok, []} ->
        IO.puts("\nNo .ex files changed since #{ref}\n")

      {:ok, files} ->
        IO.puts("\nArchdo — analyzing #{length(files)} files changed since #{ref}\n")
        run_opts = build_run_opts(opts)
        diagnostics = Runner.analyze(files, run_opts)

        exit_status = Formatter.format(diagnostics, run_opts)
        maybe_exit(exit_status)

      {:error, reason} ->
        IO.puts(:standard_error, "[archdo] #{reason}")
    end
  end

  defp changed_files_since(ref, base_paths) do
    case System.cmd("git", ["diff", "--name-only", "--diff-filter=ACMR", ref, "--"] ++ base_paths,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&(String.ends_with?(&1, ".ex") and File.exists?(&1)))

        {:ok, files}

      {error, _} ->
        {:error, "git diff failed: #{String.trim(error)}"}
    end
  end

  # --- --fix ---

  defp run_fix(opts, paths) do
    dry_run = Keyword.get(opts, :dry_run, true)

    IO.puts(
      :standard_error,
      "[archdo] --fix is experimental. Use --fix --no-dry-run to apply changes."
    )

    run_opts = build_run_opts(opts)
    files = Archdo.collect_files(paths)
    diagnostics = Runner.analyze(files, run_opts)

    fixable = Enum.filter(diagnostics, &auto_fixable?/1)

    case fixable do
      [] ->
        IO.puts("\nNo auto-fixable findings.\n")

      _ ->
        IO.puts("\nArchdo — #{length(fixable)} auto-fixable findings\n")

        case dry_run do
          true ->
            Enum.each(fixable, fn d ->
              IO.puts(
                "  [#{d.rule_id}] #{AST.relative_path(d.file)}:#{d.line} — #{d.title}"
              )
            end)

            IO.puts(
              "\nDry run — #{length(fixable)} fixes would be applied. Use --fix without --dry-run to apply.\n"
            )

          false ->
            fixed_count =
              fixable
              |> Enum.group_by(& &1.file)
              |> Enum.reduce(0, fn {file, file_diags}, count ->
                applied = apply_fixes(file, file_diags)
                count + applied
              end)

            IO.puts("Applied #{fixed_count} fixes. Run `mix format` to clean up formatting.\n")
        end
    end
  end

  @auto_fix_rules ["4.27", "6.33", "6.41"]

  defp auto_fixable?(%{rule_id: rule_id}), do: rule_id in @auto_fix_rules

  defp apply_fixes(file, diagnostics) do
    case File.read(file) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        # Process from bottom to top so line numbers stay valid
        sorted = Enum.sort_by(diagnostics, & &1.line, :desc)

        {new_lines, count} =
          Enum.reduce(sorted, {lines, 0}, fn diag, {current_lines, fixed} ->
            case apply_single_fix(diag, current_lines) do
              {:fixed, updated} -> {updated, fixed + 1}
              :skip -> {current_lines, fixed}
            end
          end)

        case count > 0 do
          true ->
            File.write!(file, Enum.join(new_lines, "\n"))
            IO.puts("  #{Path.relative_to_cwd(file)}: #{count} fixes applied")

          false ->
            :ok
        end

        count

      {:error, _} ->
        0
    end
  end

  # Remove unused alias lines
  defp apply_single_fix(%{rule_id: "4.27", line: line}, lines) do
    idx = line - 1

    case Enum.at(lines, idx) do
      nil ->
        :skip

      line_content ->
        case String.contains?(line_content, "alias ") do
          true -> {:fixed, List.delete_at(lines, idx)}
          false -> :skip
        end
    end
  end

  # Rewrite inline single-with: "with {:ok, v} <- expr, do: body" → "case expr do ..."
  defp apply_single_fix(%{rule_id: "6.41", line: line}, lines) do
    idx = line - 1

    case Enum.at(lines, idx) do
      nil ->
        :skip

      original ->
        indent = String.length(original) - String.length(String.trim_leading(original))
        prefix = String.duplicate(" ", indent)
        trimmed = String.trim(original)

        # Only auto-fix inline form: with pattern <- expr, do: body
        case Regex.run(~r/^with\s+(.+?)\s*<-\s*(.+?),\s*do:\s*(.+)$/, trimmed) do
          [_, pattern, expr, body] ->
            error_clause =
              cond do
                String.starts_with?(pattern, "{:ok") -> "{:error, _} = error -> error"
                String.starts_with?(pattern, ":ok") -> "{:error, _} = error -> error"
                true -> "other -> other"
              end

            replacement = [
              "#{prefix}case #{expr} do",
              "#{prefix}  #{pattern} -> #{body}",
              "#{prefix}  #{error_clause}",
              "#{prefix}end"
            ]

            {:fixed, List.replace_at(lines, idx, Enum.join(replacement, "\n"))}

          _ ->
            :skip
        end
    end
  end

  # Rewrite single pipe: "  x |> func(args)" → "  func(x, args)"
  defp apply_single_fix(
         %{rule_id: "6.33", title: "Code slop: single-step pipeline" <> _, line: line},
         lines
       ) do
    idx = line - 1

    case Enum.at(lines, idx) do
      nil ->
        :skip

      original ->
        indent = String.length(original) - String.length(String.trim_leading(original))
        prefix = String.duplicate(" ", indent)
        trimmed = String.trim(original)

        case rewrite_single_pipe(trimmed) do
          nil -> :skip
          ^trimmed -> :skip
          fixed -> {:fixed, List.replace_at(lines, idx, prefix <> fixed)}
        end
    end
  end

  defp apply_single_fix(_, _), do: :skip

  defp rewrite_single_pipe(line) do
    case Regex.run(~r/^(.+?)\s*\|>\s*(.+)$/, line) do
      [_, input, call] ->
        input = String.trim(input)

        case safe_pipe_rewrite?(input, line) do
          true -> rewrite_pipe_call_cli(input, call)
          false -> nil
        end

      _ ->
        nil
    end
  end

  defp safe_pipe_rewrite?(input, _line) do
    String.match?(input, ~r/^[a-z_]\w*$/) or
      String.match?(input, ~r/^[a-z_]\w*\(.*\)$/) or
      String.match?(input, ~r/^[A-Z]\w*(?:\.[A-Z]\w*)*\.[a-z_]\w*\(.*\)$/) or
      String.match?(input, ~r/^\[.*\]$/)
  end

  defp rewrite_pipe_call_cli(input, call) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_.]*(?:\.[a-z_][a-z0-9_!?]*)?)\((.*)\)$/s, call) do
      [_, func_name, existing_args] ->
        new_args =
          case String.trim(existing_args) do
            "" -> input
            args -> "#{input}, #{args}"
          end

        "#{func_name}(#{new_args})"

      _ ->
        case Regex.run(
               ~r/^([A-Za-z_][A-Za-z0-9_.]*(?:\.[a-z_][a-z0-9_!?]*)?)$/,
               String.trim(call)
             ) do
          [_, func_name] -> "#{func_name}(#{input})"
          _ -> nil
        end
    end
  end

  # --- --watch ---

  defp run_watch(opts, paths) do
    IO.puts("\nArchdo — watching #{Enum.join(paths, ", ")} for changes (Ctrl+C to stop)\n")

    run_normal(opts, paths)

    watch_loop(opts, paths, file_mtimes(paths))
  end

  defp watch_loop(opts, paths, last_mtimes) do
    Process.sleep(2_000)

    current = file_mtimes(paths)

    case current != last_mtimes do
      true ->
        IO.puts("\n--- File change detected ---\n")
        run_normal(opts, paths)
        watch_loop(opts, paths, current)

      false ->
        watch_loop(opts, paths, last_mtimes)
    end
  end

  defp file_mtimes(paths) do
    paths
    |> Enum.flat_map(fn path ->
      Path.wildcard(Path.join(path, "**/*.ex"))
    end)
    |> Map.new(fn file ->
      case File.stat(file) do
        {:ok, %{mtime: mtime}} -> {file, mtime}
        _ -> {file, nil}
      end
    end)
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

  defp parse_format("summary"), do: :summary
  defp parse_format("text"), do: :text
  defp parse_format("brief"), do: :brief
  defp parse_format("json"), do: :json
  defp parse_format("compact"), do: :compact
  defp parse_format("llm"), do: :llm
  defp parse_format("sarif"), do: :sarif
  defp parse_format("html"), do: :html
  defp parse_format(other), do: raise("Unknown format: #{other}")

  defp parse_list(str), do: String.split(str, ",", trim: true)

  defp parse_nullable_list(nil), do: nil
  defp parse_nullable_list(str), do: parse_list(str)

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
