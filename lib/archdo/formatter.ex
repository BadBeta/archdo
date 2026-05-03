defmodule Archdo.Formatter do
  @moduledoc false

  alias Archdo.{AST, Diagnostic, Fix}

  defguardp is_non_empty_string(s) when is_binary(s) and s != ""

  @doc """
  Format diagnostics to stdout. Returns exit status (0 = clean, 1 = warnings, 2 = errors).
  """
  @spec format([Archdo.Diagnostic.t()], keyword()) :: non_neg_integer()
  def format(diagnostics, opts \\ []) do
    case Keyword.get(opts, :format, :summary) do
      :summary -> format_summary(diagnostics)
      :text -> format_text(diagnostics)
      :brief -> format_brief(diagnostics)
      :json -> format_json(diagnostics)
      :compact -> format_compact(diagnostics)
      :llm -> format_llm(diagnostics)
      :sarif -> format_sarif(diagnostics)
      :html -> format_html(diagnostics)
    end
  end

  # ───────────────────────────────────��──────── :summary ───────────────────────────────────────────

  @llm_instruction """
  [Archdo] To evaluate these findings, load the Elixir skill (/elixir) and consult:
    OTP rules (5.x) → otp-reference.md | Architecture (1.x, 4.x) → architecture-reference.md
    Testing (7.x) → elixir-testing skill | NIF (11.x) → rust-nif skill
    Error handling (6.9-6.11) → language-patterns.md | Event sourcing (8.x) → event-sourcing skill
  Not every finding needs fixing — use the skill's domain knowledge to distinguish real issues from intentional trade-offs.
  """

  defp format_summary([]) do
    IO.puts("\nArchdo — no issues found.\n")
    0
  end

  defp format_summary(diagnostics) do
    {actionable, passed} = split_passed(diagnostics)
    {errors, warnings, infos, nitpicks} = counts(actionable)
    passed_n = length(passed)
    total = errors + warnings + infos + nitpicks

    IO.puts(
      "\nArchdo — #{total} findings (#{errors} errors, #{warnings} warnings, #{infos} info, #{passed_n} passed)\n"
    )

    by_rule =
      actionable
      |> Enum.group_by(fn d -> {d.rule_id, d.severity, d.title} end)
      |> Enum.map(fn {{rule_id, severity, title}, diags} ->
        tags = diags |> List.first() |> Map.get(:tags, [])
        %{rule_id: rule_id, severity: severity, title: title, count: length(diags), tags: tags}
      end)
      |> Enum.sort_by(fn r -> {severity_sort(r.severity), -r.count} end)

    has_tags = Enum.any?(by_rule, fn r -> r.tags != [] end)

    # Markdown pipe table
    case has_tags do
      true ->
        IO.puts("| Sev     | Rule  | Count | Tag  | Finding |")
        IO.puts("|---------|-------|------:|------|---------|")

      false ->
        IO.puts("| Sev     | Rule  | Count | Finding |")
        IO.puts("|---------|-------|------:|---------|")
    end

    Enum.each(by_rule, fn r ->
      sev = severity_label(r.severity)
      tag_str = Enum.map_join(r.tags, ",", &Atom.to_string/1)

      base =
        "| " <>
          String.pad_trailing(sev, 7) <>
          " | " <>
          String.pad_trailing(r.rule_id, 5) <>
          " | " <> String.pad_leading(Integer.to_string(r.count), 5)

      case has_tags do
        true ->
          IO.puts(base <> " | " <> String.pad_trailing(tag_str, 4) <> " | " <> r.title <> " |")

        false ->
          IO.puts(base <> " | " <> r.title <> " |")
      end
    end)

    IO.puts("\n#{total} total across #{length(by_rule)} rules\n")
    IO.puts(@llm_instruction)

    exit_code(errors, warnings)
  end

  defp severity_sort(:error), do: 0
  defp severity_sort(:warning), do: 1
  defp severity_sort(:info), do: 2
  defp severity_sort(:nitpick), do: 3

  defp severity_label(:error), do: "error"
  defp severity_label(:warning), do: "warn"
  defp severity_label(:info), do: "info"
  defp severity_label(:nitpick), do: "nit"

  # ───────────────────────────────────────────── :text ─────────────────────────────────────────────

  defp format_text([]) do
    IO.puts("\nArchdo — no issues found.\n")
    0
  end

  defp format_text(diagnostics) do
    IO.puts("\nArchdo — Architectural Quality Check\n")

    diagnostics
    |> Enum.group_by(&category/1)
    |> Enum.sort_by(fn {cat, _} -> category_order(cat) end)
    |> Enum.each(fn {category, diags} ->
      IO.puts("#{category}")
      Enum.each(diags, &print_full_diagnostic/1)
    end)

    {errors, warnings, infos, nitpicks} = counts(diagnostics)

    IO.puts(
      "Found #{errors} errors, #{warnings} warnings, #{infos} info, #{nitpicks} nitpicks.\n"
    )
    IO.puts(@llm_instruction)
    exit_code(errors, warnings)
  end

  # ───────────────────────────────────────────── :brief ────────────────────────────────────────────

  # Verbose for warns/errors (full why+fixes), info elided to a count line.
  # Right shape for CI runs that want fixes for actionable findings without
  # the noise of every info-level finding.
  defp format_brief([]) do
    IO.puts("\nArchdo — no issues found.\n")
    0
  end

  defp format_brief(diagnostics) do
    {non_passed, passed} = split_passed(diagnostics)
    {actionable, infos} = Enum.split_with(non_passed, fn d -> d.severity not in [:info, :nitpick] end)
    passed_n = length(passed)

    case actionable do
      [] ->
        :ok

      _ ->
        IO.puts("\nArchdo — Architectural Quality Check\n")

        actionable
        |> Enum.group_by(&category/1)
        |> Enum.sort_by(fn {cat, _} -> category_order(cat) end)
        |> Enum.each(fn {category, diags} ->
          IO.puts("#{category}")
          Enum.each(diags, &print_full_diagnostic/1)
        end)
    end

    {errors, warnings, _, _} = counts(actionable)
    info_count = length(infos)

    IO.puts(
      "Found #{errors} errors, #{warnings} warnings, #{info_count} info, #{passed_n} passed.\n"
    )

    case info_count do
      0 ->
        :ok

      n ->
        IO.puts(
          "(#{n} info finding(s) elided — run `mix archdo --format text` for full detail)\n"
        )
    end

    IO.puts(@llm_instruction)
    exit_code(errors, warnings)
  end

  # Split diagnostics into {non_passed, passed} based on the :passed tag.
  # Positive findings (e.g., "fully mockable") carry tags: [:passed] so they
  # don't clutter the actionable counts in summary/brief output.
  defp split_passed(diagnostics) do
    Enum.split_with(diagnostics, fn d -> :passed not in (d.tags || []) end)
  end

  defp print_full_diagnostic(d) do
    severity_str = format_severity(d.severity)
    IO.puts("  #{severity_str} [#{d.rule_id}] #{d.title}")
    IO.puts("         #{d.message}")
    IO.puts("         in #{AST.relative_path(d.file)}:#{d.line}")

    case see_also_for(d.rule_id) do
      nil -> :ok
      pointer -> IO.puts("         see also: #{pointer}")
    end

    if is_non_empty_string(d.why) do
      d.why
      |> wrap(80)
      |> Enum.each(fn line -> IO.puts("         why: #{line}") end)
    end

    print_alternatives(d.alternatives)

    IO.puts("")
  end

  # §§ elixir-implementing: §2.1 — empty list → noop, otherwise print.
  defp print_alternatives([]), do: :ok

  defp print_alternatives(alts) do
    IO.puts("         fixes:")

    alts
    |> Enum.with_index(1)
    |> Enum.each(fn {%Fix{} = fix, idx} -> print_alternative(fix, idx) end)
  end

  defp print_alternative(%Fix{} = fix, idx) do
    IO.puts("           #{idx}. #{fix.summary}")
    print_fix_detail(fix.detail)
    print_fix_applies_when(fix.applies_when)
  end

  defp print_fix_detail(detail) when is_binary(detail) and detail != "" do
    detail
    |> wrap(76)
    |> Enum.each(fn line -> IO.puts("              #{line}") end)
  end

  defp print_fix_detail(_), do: :ok

  defp print_fix_applies_when(applies_when) when is_binary(applies_when) and applies_when != "",
    do: IO.puts("              when: #{applies_when}")

  defp print_fix_applies_when(_), do: :ok

  # ───────────────────────────────────────────── :compact ──────────────────────────────────────────

  defp format_compact(diagnostics) do
    Enum.each(diagnostics, fn d ->
      IO.puts(
        "#{AST.relative_path(d.file)}:#{d.line}: #{d.severity} [#{d.rule_id}] #{d.title} — #{d.message}"
      )
    end)

    if match?([_ | _], diagnostics), do: IO.puts(@llm_instruction)

    {errors, warnings, _, _} = counts(diagnostics)
    exit_code(errors, warnings)
  end

  # ───────────────────────────────────────────── :json ─────────────────────────────────────────────

  defp format_json(diagnostics) do
    payload = %{
      summary: summary_map(diagnostics),
      diagnostics: Enum.map(diagnostics, &diagnostic_to_map/1)
    }

    IO.puts(Jason.encode!(payload, pretty: true))
    {errors, warnings, _, _} = counts(diagnostics)
    exit_code(errors, warnings)
  end

  # ───────────────────────────────────────────── :llm ──────────────────────────────────────────────

  # NDJSON: one diagnostic per line, each augmented with a pre-rendered markdown block.
  # First line is a `{"type":"summary",...}` envelope so consumers can short-circuit.
  defp format_llm(diagnostics) do
    instruction = %{type: "instruction", message: String.trim(@llm_instruction)}
    IO.puts(Jason.encode!(instruction))

    summary = Map.put(summary_map(diagnostics), :type, "summary")
    IO.puts(Jason.encode!(summary))

    Enum.each(diagnostics, fn d ->
      d
      |> diagnostic_to_map()
      |> Map.put(:type, "diagnostic")
      |> Map.put(:markdown, render_markdown(d))
      |> Jason.encode!()
      |> IO.puts()
    end)

    {errors, warnings, _, _} = counts(diagnostics)
    exit_code(errors, warnings)
  end

  # ───────────────────────────────────────────── :sarif ────────────────────────────────────────────

  # SARIF (Static Analysis Results Interchange Format) for GitHub Code Scanning
  defp format_sarif(diagnostics) do
    results =
      Enum.map(diagnostics, fn d ->
        %{
          ruleId: d.rule_id,
          level: sarif_level(d.severity),
          message: %{text: "#{d.title}: #{d.message}"},
          locations: [
            %{
              physicalLocation: %{
                artifactLocation: %{uri: AST.relative_path(d.file)},
                region: %{startLine: max(d.line, 1)}
              }
            }
          ]
        }
      end)

    rules =
      diagnostics
      |> Enum.uniq_by(& &1.rule_id)
      |> Enum.map(fn d ->
        %{
          id: d.rule_id,
          shortDescription: %{text: d.title},
          fullDescription: %{text: d.why || d.message},
          defaultConfiguration: %{level: sarif_level(d.severity)}
        }
      end)

    sarif = %{
      "$schema" =>
        "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
      version: "2.1.0",
      runs: [
        %{
          tool: %{
            driver: %{
              name: "Archdo",
              version: Mix.Project.config()[:version] || "0.1.0",
              informationUri: "https://github.com/BadBeta/archdo",
              rules: rules
            }
          },
          results: results
        }
      ]
    }

    IO.puts(Jason.encode!(sarif, pretty: true))
    {errors, warnings, _, _} = counts(diagnostics)
    exit_code(errors, warnings)
  end

  defp sarif_level(:error), do: "error"
  defp sarif_level(:warning), do: "warning"
  defp sarif_level(:info), do: "note"
  # SARIF spec only defines none/note/warning/error — map :nitpick to note.
  defp sarif_level(:nitpick), do: "note"

  # ───────────────────────────────────────────── :html ─────────────────────────────────────────────

  defp format_html(diagnostics) do
    {errors, warnings, infos, nitpicks} = counts(diagnostics)
    total = errors + warnings + infos + nitpicks

    by_rule =
      diagnostics
      |> Enum.group_by(fn d -> {d.rule_id, d.severity, d.title} end)
      |> Enum.map(fn {{rule_id, severity, title}, diags} ->
        %{rule_id: rule_id, severity: severity, title: title, count: length(diags)}
      end)
      |> Enum.sort_by(fn r -> {severity_sort(r.severity), -r.count} end)

    summary_rows =
      Enum.map_join(by_rule, "\n", fn r ->
        sev_class = Atom.to_string(r.severity)

        "<tr class=\"#{sev_class}\"><td>#{r.severity}</td><td>#{r.rule_id}</td>" <>
          "<td>#{r.count}</td><td>#{r.title}</td></tr>"
      end)

    detail_rows =
      Enum.map_join(diagnostics, "\n", fn d ->
        sev_class = Atom.to_string(d.severity)

        why_html =
          if d.why && d.why != "", do: "<p class=\"why\">#{escape_html(d.why)}</p>", else: ""

        "<tr class=\"#{sev_class}\">" <>
          "<td>#{d.severity}</td><td>#{d.rule_id}</td>" <>
          "<td>#{escape_html(AST.relative_path(d.file))}:#{d.line}</td>" <>
          "<td>#{escape_html(d.message)}#{why_html}</td></tr>"
      end)

    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Archdo Report — #{total} findings</title>
    <style>
      body { font-family: system-ui, sans-serif; margin: 2rem; background: #1a1a2e; color: #e0e0e0; }
      h1 { color: #fff; } h2 { color: #ccc; margin-top: 2rem; }
      table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
      th, td { padding: 0.4rem 0.8rem; text-align: left; border: 1px solid #333; }
      th { background: #16213e; color: #fff; }
      tr.error td { background: #3d1f1f; } tr.warning td { background: #3d3a1f; }
      tr.info td { background: #1f2d3d; }
      .why { font-size: 0.85em; color: #aaa; margin: 0.3rem 0 0; }
      .summary { font-size: 1.1em; margin: 1rem 0; }
    </style>
    </head>
    <body>
    <h1>Archdo Report</h1>
    <p class="summary">#{total} findings: #{errors} errors, #{warnings} warnings, #{infos} info</p>
    <h2>Summary</h2>
    <table><tr><th>Sev</th><th>Rule</th><th>Count</th><th>Finding</th></tr>
    #{summary_rows}
    </table>
    <h2>Details</h2>
    <table><tr><th>Sev</th><th>Rule</th><th>Location</th><th>Finding</th></tr>
    #{detail_rows}
    </table>
    </body></html>
    """

    File.write!("archdo_report.html", html)
    IO.puts("Report written to archdo_report.html (#{total} findings)")
    exit_code(errors, warnings)
  end

  defp escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_html(_), do: ""

  # ──────────────────────────────────────── shared helpers ─────────────────────────────────────────

  defp diagnostic_to_map(%Diagnostic{} = d) do
    %{
      rule_id: d.rule_id,
      severity: d.severity,
      title: d.title,
      message: d.message,
      why: d.why,
      alternatives: Enum.map(d.alternatives, &fix_to_map/1),
      references: d.references,
      context: d.context,
      tags: d.tags,
      file: AST.relative_path(d.file),
      line: d.line
    }
  end

  defp fix_to_map(%Fix{} = fix), do: Fix.to_map(fix)

  defp render_markdown(%Diagnostic{} = d) do
    [
      "### [#{d.rule_id}] #{d.title}",
      "**Severity:** #{d.severity}  \n**Location:** `#{AST.relative_path(d.file)}:#{d.line}`",
      "**Finding:** #{d.message}",
      maybe_why(d.why),
      maybe_fixes(d.alternatives),
      maybe_refs(d.references)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp maybe_why(why) when is_non_empty_string(why), do: "**Why it matters:** #{why}"
  defp maybe_why(_), do: nil

  defp maybe_fixes([]), do: nil

  defp maybe_fixes(alts) do
    fix_block =
      alts
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {%Fix{} = fix, idx} ->
        [
          "#{idx}. **#{fix.summary}**",
          if(is_non_empty_string(fix.detail), do: "\n   #{fix.detail}"),
          if(is_non_empty_string(fix.applies_when),
            do: "\n   _Use when: #{fix.applies_when}_"
          ),
          if(is_non_empty_string(fix.example),
            do: "\n\n#{indent(fix.example, "   ")}"
          )
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join()
      end)

    "**Fix options:**\n\n" <> fix_block
  end

  defp maybe_refs([]), do: nil
  defp maybe_refs(refs), do: "**References:** " <> Enum.join(refs, ", ")

  defp summary_map(diagnostics) do
    {errors, warnings, infos, nitpicks} = counts(diagnostics)

    %{
      errors: errors,
      warnings: warnings,
      infos: infos,
      nitpicks: nitpicks,
      total: errors + warnings + infos + nitpicks
    }
  end

  defp counts(diagnostics) do
    Enum.reduce(diagnostics, {0, 0, 0, 0}, fn
      %{severity: :error}, {e, w, i, n} -> {e + 1, w, i, n}
      %{severity: :warning}, {e, w, i, n} -> {e, w + 1, i, n}
      %{severity: :info}, {e, w, i, n} -> {e, w, i + 1, n}
      %{severity: :nitpick}, {e, w, i, n} -> {e, w, i, n + 1}
      _, acc -> acc
    end)
  end

  defp exit_code(errors, warnings) do
    cond do
      errors > 0 -> 2
      warnings > 0 -> 1
      true -> 0
    end
  end

  defp format_severity(:error), do: IO.ANSI.format([:red, "error  "])
  defp format_severity(:warning), do: IO.ANSI.format([:yellow, "warning"])
  defp format_severity(:info), do: IO.ANSI.format([:cyan, "info   "])
  defp format_severity(:nitpick), do: IO.ANSI.format([:light_black, "nitpick"])

  # Per-rule cross-references — point Layer 2 (the Elixir/rust-nif skill) at the
  # exact section that explains the trade-off behind the rule. Mapped by rule_id
  # prefix so a single line covers a whole category. Returns nil for prefixes
  # without a known pointer (no see-also line emitted).
  # Topic-only references (no §-numbers): topic names survive document
  # renumbering, so these don't need to chase skill revisions.
  @spec see_also_for(String.t()) :: String.t() | nil
  defp see_also_for("11." <> _), do: "rust-nif skill (NIF module shapes)"

  defp see_also_for("5." <> _),
    do: "elixir-implementing (OTP key decisions); elixir-reviewing (OTP checklist)"

  defp see_also_for("4." <> _),
    do: "elixir-planning (architecture-patterns); elixir-reviewing (architecture checklist)"

  defp see_also_for("1." <> _),
    do: "elixir-planning (data-ownership); elixir-reviewing (boundaries checklist)"

  defp see_also_for("3." <> _), do: "elixir-implementing (config strategy / Config module)"

  defp see_also_for("6." <> _),
    do: "elixir-implementing (anti-patterns); elixir-reviewing (control-flow)"

  defp see_also_for("7." <> _), do: "elixir-implementing (TDD workflow / testing-patterns)"
  defp see_also_for("8." <> _), do: "event-sourcing skill"

  defp see_also_for("9." <> _),
    do: "state-machine skill; elixir-implementing (gen_statem callback modes)"

  defp see_also_for("10." <> _), do: "elixir-implementing (architecture key decisions)"

  defp see_also_for("2." <> _),
    do: "elixir-implementing (context modules); elixir-reviewing (public-api)"

  defp see_also_for(_), do: nil

  defp category(%Diagnostic{rule_id: "5." <> _}), do: "OTP Process Architecture"
  defp category(%Diagnostic{rule_id: "2." <> _}), do: "Public API"
  defp category(%Diagnostic{rule_id: "4." <> _}), do: "Coupling & Abstraction"
  defp category(%Diagnostic{rule_id: "6." <> _}), do: "Module Quality"
  defp category(%Diagnostic{rule_id: "8." <> _}), do: "Event Sourcing"
  defp category(%Diagnostic{rule_id: "9." <> _}), do: "State Machine"
  defp category(%Diagnostic{rule_id: "10." <> _}), do: "Composition"
  defp category(%Diagnostic{rule_id: "11." <> _}), do: "Native Interop"
  defp category(%Diagnostic{rule_id: "1." <> _}), do: "Boundaries"
  defp category(%Diagnostic{rule_id: "3." <> _}), do: "Single Source of Truth"
  defp category(%Diagnostic{rule_id: "7." <> _}), do: "Test Architecture"
  defp category(_), do: "Other"

  defp category_order("Boundaries"), do: 0
  defp category_order("Coupling & Abstraction"), do: 1
  defp category_order("OTP Process Architecture"), do: 2
  defp category_order("Public API"), do: 3
  defp category_order("Single Source of Truth"), do: 4
  defp category_order("Module Quality"), do: 5
  defp category_order("Event Sourcing"), do: 6
  defp category_order("State Machine"), do: 7
  defp category_order("Test Architecture"), do: 8
  defp category_order("Composition"), do: 9
  defp category_order("Native Interop"), do: 10
  defp category_order(_), do: 11

  # Word-wrap a string at the given column count, returning a list of lines.
  defp wrap(text, width) when is_binary(text) and width > 0 do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce({[], ""}, fn word, {lines, current} ->
      cond do
        current == "" -> {lines, word}
        byte_size(current) + 1 + byte_size(word) <= width -> {lines, current <> " " <> word}
        true -> {[current | lines], word}
      end
    end)
    |> then(fn {lines, current} ->
      case current do
        "" -> Enum.reverse(lines)
        _ -> Enum.reverse([current | lines])
      end
    end)
  end

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(prefix <> &1))
  end
end
