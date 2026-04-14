defmodule Archdo.Formatter do
  @moduledoc false

  alias Archdo.{Diagnostic, Fix}

  @doc """
  Format diagnostics to stdout. Returns exit status (0 = clean, 1 = warnings, 2 = errors).
  """
  @spec format([Archdo.Diagnostic.t()], keyword()) :: non_neg_integer()
  def format(diagnostics, opts \\ []) do
    case Keyword.get(opts, :format, :text) do
      :text -> format_text(diagnostics)
      :json -> format_json(diagnostics)
      :compact -> format_compact(diagnostics)
      :llm -> format_llm(diagnostics)
    end
  end

  # ───────────────────────────────────────────── :text ─────────────────────────────────────────────

  @llm_instruction """
  [Archdo] To evaluate these findings, load the Elixir skill (/elixir) and consult:
    OTP rules (5.x) → otp-reference.md | Architecture (1.x, 4.x) → architecture-reference.md
    Testing (7.x) → elixir-testing skill | NIF (11.x) → rust-nif skill
    Error handling (6.9-6.11) → language-patterns.md | Event sourcing (8.x) → event-sourcing skill
  Not every finding needs fixing — use the skill's domain knowledge to distinguish real issues from intentional trade-offs.
  """

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

      Enum.each(diags, fn d ->
        severity_str = format_severity(d.severity)
        IO.puts("  #{severity_str} [#{d.rule_id}] #{d.title}")
        IO.puts("         #{d.message}")
        IO.puts("         in #{relative_path(d.file)}:#{d.line}")

        if is_binary(d.why) and d.why != "" do
          d.why
          |> wrap(80)
          |> Enum.each(fn line -> IO.puts("         why: #{line}") end)
        end

        case d.alternatives do
          [] ->
            :ok

          alts ->
            IO.puts("         fixes:")

            alts
            |> Enum.with_index(1)
            |> Enum.each(fn {%Fix{} = fix, idx} ->
              IO.puts("           #{idx}. #{fix.summary}")

              if is_binary(fix.detail) and fix.detail != "" do
                fix.detail
                |> wrap(76)
                |> Enum.each(fn line -> IO.puts("              #{line}") end)
              end

              if is_binary(fix.applies_when) and fix.applies_when != "" do
                IO.puts("              when: #{fix.applies_when}")
              end
            end)
        end

        IO.puts("")
      end)
    end)

    {errors, warnings, infos} = counts(diagnostics)
    IO.puts("Found #{errors} errors, #{warnings} warnings, #{infos} info.\n")
    IO.puts(@llm_instruction)
    exit_code(errors, warnings)
  end

  # ───────────────────────────────────────────── :compact ──────────────────────────────────────────

  defp format_compact(diagnostics) do
    Enum.each(diagnostics, fn d ->
      IO.puts(
        "#{relative_path(d.file)}:#{d.line}: #{d.severity} [#{d.rule_id}] #{d.title} — #{d.message}"
      )
    end)

    if match?([_ | _], diagnostics), do: IO.puts(@llm_instruction)

    {errors, warnings, _} = counts(diagnostics)
    exit_code(errors, warnings)
  end

  # ───────────────────────────────────────────── :json ─────────────────────────────────────────────

  defp format_json(diagnostics) do
    payload = %{
      summary: summary_map(diagnostics),
      diagnostics: Enum.map(diagnostics, &diagnostic_to_map/1)
    }

    IO.puts(Jason.encode!(payload, pretty: true))
    {errors, warnings, _} = counts(diagnostics)
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

    {errors, warnings, _} = counts(diagnostics)
    exit_code(errors, warnings)
  end

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
      file: relative_path(d.file),
      line: d.line
    }
  end

  defp fix_to_map(%Fix{} = fix) do
    %{
      summary: fix.summary,
      detail: fix.detail,
      example: fix.example,
      applies_when: fix.applies_when
    }
  end

  defp render_markdown(%Diagnostic{} = d) do
    [
      "### [#{d.rule_id}] #{d.title}",
      "**Severity:** #{d.severity}  \n**Location:** `#{relative_path(d.file)}:#{d.line}`",
      "**Finding:** #{d.message}",
      maybe_why(d.why),
      maybe_fixes(d.alternatives),
      maybe_refs(d.references)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp maybe_why(why) when is_binary(why) and why != "", do: "**Why it matters:** #{why}"
  defp maybe_why(_), do: nil

  defp maybe_fixes([]), do: nil

  defp maybe_fixes(alts) do
    fix_block =
      alts
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {%Fix{} = fix, idx} ->
        [
          "#{idx}. **#{fix.summary}**",
          if(fix.detail not in [nil, ""], do: "\n   #{fix.detail}"),
          if(is_binary(fix.applies_when) and fix.applies_when != "",
            do: "\n   _Use when: #{fix.applies_when}_"
          ),
          if(is_binary(fix.example) and fix.example != "",
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
    {errors, warnings, infos} = counts(diagnostics)
    %{errors: errors, warnings: warnings, infos: infos, total: errors + warnings + infos}
  end

  defp counts(diagnostics) do
    Enum.reduce(diagnostics, {0, 0, 0}, fn
      %{severity: :error}, {e, w, i} -> {e + 1, w, i}
      %{severity: :warning}, {e, w, i} -> {e, w + 1, i}
      %{severity: :info}, {e, w, i} -> {e, w, i + 1}
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

  defp relative_path(path) do
    case File.cwd() do
      {:ok, cwd} -> Path.relative_to(path, cwd)
      _ -> path
    end
  end

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
      if current == "", do: Enum.reverse(lines), else: Enum.reverse([current | lines])
    end)
  end

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(prefix <> &1))
  end
end
