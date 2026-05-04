defmodule Archdo.Stats do
  @moduledoc """
  Project-wide statistics collector. Aggregates source/test file
  counts, line counts, module counts, public/private function ratio,
  `@spec` and `@moduledoc` coverage, GenServer / Ecto schema /
  behaviour counts, and per-context coupling/cohesion metrics.

  Public API consumed by `mix archdo --stats`, the standard report
  layout, and the MCP `stats` tool.
  """

  # Reading lib/test source files IS the responsibility.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  alias Archdo.AST
  alias Archdo.Compiled

  @doc """
  Collect comprehensive project statistics from source files.
  Returns a map with all metrics, suitable for formatting.
  """
  @spec collect(list(String.t())) :: map()
  def collect(paths) do
    # Always include both source and test paths for full stats
    all_paths = expand_with_tests(paths)
    files = Archdo.collect_files(all_paths)

    {lib_files, test_files} =
      Enum.split_with(files, fn f -> not AST.test_file?(f) end)

    lib_stats = analyze_files(lib_files)
    test_stats = analyze_files(test_files)
    contexts = discover_contexts(paths)

    %{
      lib: lib_stats,
      test: test_stats,
      total: merge_stats(lib_stats, test_stats),
      contexts: contexts,
      paths: paths
    }
  end

  @doc """
  Format statistics as a readable report string.
  """
  @spec format(map()) :: String.t()
  def format(stats) do
    [
      format_header(stats),
      "",
      format_section("Source (lib/)", stats.lib),
      "",
      format_section("Tests (test/)", stats.test),
      "",
      format_totals(stats.total),
      "",
      format_elixir_breakdown(stats),
      "",
      format_contexts(stats.contexts)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  # Try to discover contexts from compiled beams. Returns [] if no beams found.
  defp discover_contexts(paths) do
    # Infer project root from the first path
    project_root =
      paths
      |> List.first()
      |> then(fn
        nil ->
          "."

        "lib" ->
          "."

        path when is_binary(path) ->
          case String.ends_with?(path, "/lib") do
            true -> String.replace_suffix(path, "/lib", "")
            false -> Path.dirname(path)
          end
      end)

    case Compiled.analyze(project_root) do
      {:ok, graph} ->
        Compiled.discover_contexts(graph)
        |> Enum.map(fn ctx ->
          %{
            name: ctx.context,
            modules: length(ctx.members),
            cohesion: ctx.cohesion,
            coupling: ctx.coupling,
            internal_calls: ctx.internal_calls,
            incoming_calls: ctx.incoming_calls,
            outgoing_calls: ctx.outgoing_calls,
            leak_calls: ctx.leak_calls,
            boundary: ctx.boundary_module && inspect(ctx.boundary_module)
          }
        end)
        |> Enum.sort_by(fn c -> -c.modules end)

      {:error, _} ->
        []
    end
  end

  # When given ["lib"], also scan ["test"] for test stats.
  # When given explicit paths like ["/tmp/oban/lib"], infer the test sibling.
  defp expand_with_tests(paths) do
    test_paths =
      paths
      |> Enum.flat_map(&sibling_test_path/1)
      |> Enum.uniq()

    Enum.uniq(paths ++ test_paths)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatches on the
  # path shape (the suffix); helpers dispatch on the boolean predicate
  # results via multi-clause heads, never if/else.
  defp sibling_test_path("lib"), do: dir_or_empty("test")
  defp sibling_test_path(path), do: maybe_test_for_lib(String.ends_with?(path, "/lib"), path)

  defp maybe_test_for_lib(false, _path), do: []

  defp maybe_test_for_lib(true, path),
    do: dir_or_empty(String.replace_suffix(path, "/lib", "/test"))

  defp dir_or_empty(dir), do: existing_dir(File.dir?(dir), dir)
  defp existing_dir(false, _dir), do: []
  defp existing_dir(true, dir), do: [dir]

  # --- File analysis ---

  defp analyze_files(files) do
    file_results = Enum.map(files, &analyze_file/1)

    %{
      files: length(files),
      lines: sum_field(file_results, :lines),
      code_lines: sum_field(file_results, :code_lines),
      comment_lines: sum_field(file_results, :comment_lines),
      blank_lines: sum_field(file_results, :blank_lines),
      modules: sum_field(file_results, :modules),
      public_fns: sum_field(file_results, :public_fns),
      private_fns: sum_field(file_results, :private_fns),
      macros: sum_field(file_results, :macros),
      tests: sum_field(file_results, :tests),
      describes: sum_field(file_results, :describes),
      genservers: sum_field(file_results, :genservers),
      supervisors: sum_field(file_results, :supervisors),
      schemas: sum_field(file_results, :schemas),
      behaviours_defined: sum_field(file_results, :behaviours_defined),
      behaviours_implemented: sum_field(file_results, :behaviours_implemented),
      protocols: sum_field(file_results, :protocols),
      structs: sum_field(file_results, :structs),
      specs: sum_field(file_results, :specs),
      moduledocs: sum_field(file_results, :moduledocs),
      avg_module_lines: avg_module_lines(file_results),
      largest_module: largest_module(file_results)
    }
  end

  defp analyze_file(path) do
    case File.read(path) do
      {:ok, content} ->
        do_analyze_file(path, content)

      {:error, _} ->
        Map.merge(empty_ast_stats(), %{
          file: path,
          lines: 0,
          code_lines: 0,
          comment_lines: 0,
          blank_lines: 0
        })
    end
  end

  defp do_analyze_file(path, content) do
    lines = String.split(content, "\n")
    line_count = length(lines)

    {code, comments, blanks} = classify_lines(lines)

    ast_stats =
      case Code.string_to_quoted(content, file: path) do
        {:ok, ast} -> analyze_ast(ast, path)
        {:error, _} -> empty_ast_stats()
      end

    Map.merge(ast_stats, %{
      file: path,
      lines: line_count,
      code_lines: code,
      comment_lines: comments,
      blank_lines: blanks
    })
  end

  defp classify_lines(lines) do
    Enum.reduce(lines, {0, 0, 0}, fn line, {code, comments, blanks} ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" -> {code, comments, blanks + 1}
        String.starts_with?(trimmed, "#") -> {code, comments + 1, blanks}
        true -> {code + 1, comments, blanks}
      end
    end)
  end

  defp analyze_ast(ast, path) do
    {_, counts} = Macro.prewalk(ast, empty_ast_stats(), &count_node(&1, &2, path))
    counts
  end

  defp count_node({:defmodule, _, _} = node, acc, _path),
    do: {node, %{acc | modules: acc.modules + 1}}

  defp count_node({:def, meta, [{name, _, _} | _]} = node, acc, path)
       when is_atom(name) do
    {node,
     %{
       acc
       | public_fns: acc.public_fns + 1,
         module_lines: [{path, name, AST.line(meta)} | acc.module_lines]
     }}
  end

  defp count_node({:defp, _, [{name, _, _} | _]} = node, acc, _path)
       when is_atom(name),
       do: {node, %{acc | private_fns: acc.private_fns + 1}}

  defp count_node({:defmacro, _, [{name, _, _} | _]} = node, acc, _path)
       when is_atom(name),
       do: {node, %{acc | macros: acc.macros + 1}}

  defp count_node({:defmacrop, _, [{name, _, _} | _]} = node, acc, _path)
       when is_atom(name),
       do: {node, %{acc | macros: acc.macros + 1}}

  defp count_node({:test, _, [_ | _]} = node, acc, _path),
    do: {node, %{acc | tests: acc.tests + 1}}

  defp count_node({:describe, _, [_ | _]} = node, acc, _path),
    do: {node, %{acc | describes: acc.describes + 1}}

  defp count_node({:use, _, [{:__aliases__, _, [:GenServer]} | _]} = node, acc, _path),
    do: {node, %{acc | genservers: acc.genservers + 1}}

  defp count_node({:use, _, [{:__aliases__, _, [:Supervisor]} | _]} = node, acc, _path),
    do: {node, %{acc | supervisors: acc.supervisors + 1}}

  defp count_node({:use, _, [{:__aliases__, _, [_, :Schema]} | _]} = node, acc, _path),
    do: {node, %{acc | schemas: acc.schemas + 1}}

  defp count_node({:schema, _, _} = node, acc, _path),
    do: {node, %{acc | schemas: max(acc.schemas, 1)}}

  defp count_node({:defstruct, _, _} = node, acc, _path),
    do: {node, %{acc | structs: acc.structs + 1}}

  defp count_node({:@, _, [{:behaviour, _, _}]} = node, acc, _path),
    do: {node, %{acc | behaviours_implemented: acc.behaviours_implemented + 1}}

  defp count_node({:@, _, [{:callback, _, _}]} = node, acc, _path),
    do: {node, %{acc | behaviours_defined: acc.behaviours_defined + 1}}

  defp count_node({:defprotocol, _, _} = node, acc, _path),
    do: {node, %{acc | protocols: acc.protocols + 1}}

  defp count_node({:@, _, [{:spec, _, _}]} = node, acc, _path),
    do: {node, %{acc | specs: acc.specs + 1}}

  # `@moduledoc false` is intentional opt-out — don't count it.
  defp count_node({:@, _, [{:moduledoc, _, [false]}]} = node, acc, _path),
    do: {node, acc}

  defp count_node({:@, _, [{:moduledoc, _, [_]}]} = node, acc, _path),
    do: {node, %{acc | moduledocs: acc.moduledocs + 1}}

  defp count_node(node, acc, _path), do: {node, acc}

  defp empty_ast_stats do
    %{
      modules: 0,
      public_fns: 0,
      private_fns: 0,
      macros: 0,
      tests: 0,
      describes: 0,
      genservers: 0,
      supervisors: 0,
      schemas: 0,
      behaviours_defined: 0,
      behaviours_implemented: 0,
      protocols: 0,
      structs: 0,
      specs: 0,
      moduledocs: 0,
      module_lines: []
    }
  end

  defp sum_field(results, field) do
    Enum.sum(Enum.map(results, &Map.get(&1, field, 0)))
  end

  defp avg_module_lines(results) do
    total_modules = sum_field(results, :modules)
    total_code = sum_field(results, :code_lines)

    case total_modules do
      0 -> 0
      n -> div(total_code, n)
    end
  end

  defp largest_module(results) do
    results
    |> Enum.max_by(fn r -> r.code_lines end, fn -> %{file: "-", code_lines: 0} end)
    |> then(fn r -> {Path.basename(r.file), r.code_lines} end)
  end

  defp merge_stats(a, b) do
    %{
      files: a.files + b.files,
      lines: a.lines + b.lines,
      code_lines: a.code_lines + b.code_lines,
      comment_lines: a.comment_lines + b.comment_lines,
      blank_lines: a.blank_lines + b.blank_lines,
      modules: a.modules + b.modules,
      public_fns: a.public_fns + b.public_fns,
      private_fns: a.private_fns + b.private_fns,
      macros: a.macros + b.macros,
      tests: a.tests + b.tests,
      describes: a.describes + b.describes,
      genservers: a.genservers + b.genservers,
      supervisors: a.supervisors + b.supervisors,
      schemas: a.schemas + b.schemas,
      behaviours_defined: a.behaviours_defined + b.behaviours_defined,
      behaviours_implemented: a.behaviours_implemented + b.behaviours_implemented,
      protocols: a.protocols + b.protocols,
      structs: a.structs + b.structs,
      specs: a.specs + b.specs,
      moduledocs: a.moduledocs + b.moduledocs,
      avg_module_lines: 0,
      largest_module: {"", 0}
    }
  end

  # --- Formatting ---

  defp format_header(_stats) do
    [
      "╔══════════════════════════════════════════════════════════╗",
      "║              Archdo — Project Statistics                 ║",
      "╚══════════════════════════════════════════════════════════╝"
    ]
  end

  defp format_section(title, stats) do
    {largest_name, largest_lines} = stats.largest_module
    total_fns = stats.public_fns + stats.private_fns

    spec_coverage =
      case stats.public_fns do
        0 -> "—"
        n -> "#{Float.round(stats.specs / n * 100, 0)}%"
      end

    doc_coverage =
      case stats.modules do
        0 -> "—"
        n -> "#{Float.round(stats.moduledocs / n * 100, 0)}%"
      end

    [
      "┌─ #{title} ─────────────────────────────────────────────",
      "│",
      row("Files", stats.files),
      row("Lines (total)", stats.lines),
      row("  Code", stats.code_lines),
      row("  Comments", stats.comment_lines),
      row("  Blank", stats.blank_lines),
      "│",
      row("Modules", stats.modules),
      row("  Avg lines/module", stats.avg_module_lines),
      row("  Largest file", "#{largest_name} (#{largest_lines} lines)"),
      "│",
      row("Functions (total)", total_fns),
      row("  Public (def)", stats.public_fns),
      row("  Private (defp)", stats.private_fns),
      row("  Macros", stats.macros),
      "│",
      row("@spec coverage", spec_coverage),
      row("@moduledoc coverage", doc_coverage),
      maybe_test_rows(stats),
      maybe_otp_rows(stats),
      "└──────────────────────────────────────────────────────────"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_test_rows(stats) do
    case stats.tests do
      0 ->
        nil

      _ ->
        [
          "│",
          row("Tests", stats.tests),
          row("  Describe blocks", stats.describes)
        ]
    end
  end

  defp maybe_otp_rows(stats) do
    otp_total =
      stats.genservers + stats.supervisors + stats.schemas +
        stats.protocols + stats.structs + stats.behaviours_defined

    case otp_total do
      0 ->
        nil

      _ ->
        rows = [
          "│",
          maybe_row("GenServers", stats.genservers),
          maybe_row("Supervisors", stats.supervisors),
          maybe_row("Ecto schemas", stats.schemas),
          maybe_row("Structs", stats.structs),
          maybe_row("Protocols", stats.protocols),
          maybe_row("Behaviours defined", stats.behaviours_defined),
          maybe_row("Behaviours used", stats.behaviours_implemented)
        ]

        Enum.reject(rows, &is_nil/1)
    end
  end

  defp format_totals(stats) do
    total_fns = stats.public_fns + stats.private_fns

    [
      "┌─ Totals ──────────────────────────────────────────────",
      "│",
      row("Files", stats.files),
      row("Code lines", stats.code_lines),
      row("Modules", stats.modules),
      row("Functions", total_fns),
      row("Tests", stats.tests),
      "└──────────────────────────────────────────────────────────"
    ]
  end

  defp format_elixir_breakdown(stats) do
    lib = stats.lib
    test = stats.test
    total_fns = lib.public_fns + lib.private_fns

    pub_ratio =
      case total_fns do
        0 -> "—"
        n -> "#{Float.round(lib.public_fns / n * 100, 0)}%"
      end

    [
      "┌─ Elixir Breakdown ────────────────────────────────────",
      "│",
      row("Public/Total fn ratio", pub_ratio),
      row("Code/Comment ratio", ratio_str(lib.code_lines, lib.comment_lines)),
      row("Source/Test ratio", ratio_str(lib.code_lines, test.code_lines)),
      "└──────────────────────────────────────────────────────────"
    ]
  end

  defp format_contexts([]), do: []

  defp format_contexts(contexts) do
    header = [
      "┌─ Contexts (from compiled beams) ──────────────────────",
      "│",
      "│  " <>
        String.pad_trailing("Context", 28) <>
        String.pad_trailing("Mods", 6) <>
        String.pad_trailing("Coh.", 7) <>
        String.pad_trailing("Coup.", 7) <>
        String.pad_trailing("In", 5) <>
        String.pad_trailing("Out", 5) <>
        "Leaks",
      "│  " <> String.duplicate("─", 65)
    ]

    rows =
      Enum.map(contexts, fn ctx ->
        short = ctx.name |> String.split(".") |> Enum.at(-1)
        name = String.pad_trailing(short, 28)
        mods = String.pad_trailing("#{ctx.modules}", 6)
        coh = String.pad_trailing("#{(ctx.cohesion * 100) |> Float.round(0) |> trunc()}%", 7)
        coup = String.pad_trailing("#{(ctx.coupling * 100) |> Float.round(0) |> trunc()}%", 7)
        inc = String.pad_trailing("#{ctx.incoming_calls}", 5)
        out = String.pad_trailing("#{ctx.outgoing_calls}", 5)

        leak =
          case ctx.leak_calls do
            0 -> ""
            n -> "#{n}"
          end

        "│  " <> name <> mods <> coh <> coup <> inc <> out <> leak
      end)

    total_mods = Enum.sum(Enum.map(contexts, & &1.modules))
    total_leaks = Enum.sum(Enum.map(contexts, & &1.leak_calls))

    footer = [
      "│",
      row("Contexts", length(contexts)),
      row("Modules in contexts", total_mods),
      maybe_row("Total boundary leaks", total_leaks),
      "└──────────────────────────────────────────────────────────"
    ]

    List.flatten([header, rows, Enum.reject(footer, &is_nil/1)])
  end

  defp row(label, value) do
    label_padded = String.pad_trailing("│  #{label}", 38)
    "#{label_padded}#{value}"
  end

  defp maybe_row(_label, 0), do: nil
  defp maybe_row(label, value), do: row(label, value)

  defp ratio_str(a, 0) when a > 0, do: "#{a}:0"
  defp ratio_str(0, _b), do: "0:—"

  defp ratio_str(a, b) do
    ratio = Float.round(a / b, 1)
    "#{ratio}:1"
  end
end
