defmodule Archdo.Mcp.Tools.Fix do
  @moduledoc false

  alias Archdo.Runner

  @fixable_rules ["6.33", "6.41", "4.27", "6.47", "6.50"]

  def name, do: "archdo_fix"

  def description do
    "Generate executable edit suggestions for mechanical findings that have " <>
      "deterministic fixes. Returns the original code, replacement code, and " <>
      "file location for each fixable finding. The LLM can apply these directly. " <>
      "Currently supports: single-pipe (6.33), single-clause with (6.41), " <>
      "unused alias (4.27), empty check via length (6.47), Enum.at(list, 0) (6.50)."
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "file" => %{
          "type" => "string",
          "description" => "File to generate fixes for."
        },
        "rule_id" => %{
          "type" => "string",
          "description" => "Optional: only generate fixes for this rule ID."
        }
      },
      "required" => ["file"],
      "additionalProperties" => false
    }
  end

  def call(%{"file" => file} = args) do
    call_for_existing(File.exists?(file), file, args)
  end

  def call(_), do: {:error, "Missing required argument: file"}

  # §§ elixir-implementing: §2.1 — boolean → multi-clause head dispatch
  # on file existence and on the read result tag.
  defp call_for_existing(false, file, _args), do: {:error, "File not found: #{file}"}

  defp call_for_existing(true, file, args) do
    rule_filter = rule_filter(Map.get(args, "rule_id"))
    diagnostics = Runner.analyze([file], only: rule_filter)
    fixable = Enum.filter(diagnostics, &(&1.rule_id in @fixable_rules))
    build_fixes(File.read(file), file, fixable, diagnostics)
  end

  defp rule_filter(nil), do: @fixable_rules
  defp rule_filter(id), do: [id]

  defp build_fixes({:error, reason}, file, _fixable, _diagnostics),
    do: {:error, "Cannot read #{file}: #{reason}"}

  defp build_fixes({:ok, content}, file, fixable, diagnostics) do
    lines = String.split(content, "\n")

    fixes =
      fixable
      |> Enum.map(fn d -> generate_fix(d, lines) end)
      |> Enum.reject(&is_nil/1)

    {:ok,
     %{
       file: file,
       fixable_count: length(fixes),
       total_findings: length(diagnostics),
       fixes: fixes
     }}
  end

  # Generate a fix for single-clause with → case
  defp generate_fix(%{rule_id: "6.41", line: line}, lines) do
    case Enum.at(lines, line - 1) do
      nil ->
        nil

      original_line ->
        trimmed = String.trim(original_line)

        case rewrite_single_with(trimmed, lines, line) do
          {:auto, original, replacement} ->
            %{
              rule_id: "6.41",
              line: line,
              description: "Single-clause `with` → `case`",
              original: original,
              replacement: replacement,
              auto_fixable: true
            }

          {:manual, original, suggestion} ->
            %{
              rule_id: "6.41",
              line: line,
              description: "Single-clause `with` → `case`",
              original: original,
              suggestion: suggestion,
              auto_fixable: false
            }
        end
    end
  end

  defp generate_fix(%{rule_id: "4.27", line: line}, lines) do
    case Enum.at(lines, line - 1) do
      nil ->
        nil

      original_line ->
        %{
          rule_id: "4.27",
          line: line,
          description: "Unused alias — remove the line",
          original: String.trim(original_line),
          replacement: "",
          auto_fixable: true
        }
    end
  end

  defp generate_fix(%{rule_id: "6.50", title: "Enum.at(list, 0)" <> _, line: line}, lines) do
    case Enum.at(lines, line - 1) do
      nil ->
        nil

      original_line ->
        trimmed = String.trim(original_line)
        # Try to generate replacement
        replacement = String.replace(trimmed, ~r/Enum\.at\(([^,]+),\s*0\)/, "hd(\\1)")

        case replacement == trimmed do
          true ->
            nil

          false ->
            %{
              rule_id: "6.50",
              line: line,
              description: "Enum.at(list, 0) → hd(list)",
              original: trimmed,
              replacement: replacement,
              auto_fixable: true
            }
        end
    end
  end

  defp generate_fix(
         %{rule_id: "6.33", title: "Code slop: single-step pipeline" <> _, line: line},
         lines
       ) do
    case Enum.at(lines, line - 1) do
      nil ->
        nil

      original_line ->
        trimmed = String.trim(original_line)

        case Archdo.PipeRewriter.rewrite_line(trimmed) do
          nil ->
            nil

          ^trimmed ->
            nil

          fixed ->
            %{
              rule_id: "6.33",
              line: line,
              description: "Single pipe → direct function call",
              original: trimmed,
              replacement: fixed,
              auto_fixable: true
            }
        end
    end
  end

  defp generate_fix(%{rule_id: rule_id, line: line, title: title}, lines) do
    case Enum.at(lines, line - 1) do
      nil ->
        nil

      original_line ->
        %{
          rule_id: rule_id,
          line: line,
          description: title,
          original: String.trim(original_line),
          suggestion: "See rule #{rule_id} fix alternatives for details",
          auto_fixable: false
        }
    end
  end

  # Rewrite "input |> Mod.func(args)" to "Mod.func(input, args)"
  # SAFETY checks — skip when rewriting would change semantics:
  #   - input contains assignment (x = foo() |> bar())
  #   - input is a keyword value (key: expr |> func())
  #   - input is inside a list/map/struct literal
  #   - line has trailing comma (embedded in larger expression)
  # Rewrite single-clause with to case
  defp rewrite_single_with(line, _lines, _start_line) do
    case Regex.run(~r/^with\s+(.+?)\s*<-\s*(.+?),\s*do:\s*(.+)$/, line) do
      [_, pattern, expr, body] ->
        error_clause = infer_error_clause(pattern)
        replacement = "case #{expr} do\n  #{pattern} -> #{body}\n  #{error_clause}\nend"
        {:auto, line, replacement}

      _ ->
        case Regex.run(~r/^with\s+(.+?)\s*<-\s*(.+?)\s+do\s*$/, line) do
          [_, pattern, expr] ->
            error_clause = infer_error_clause(pattern)

            suggestion =
              "case #{String.trim(expr)} do\n  #{pattern} -> ...\n  #{error_clause}\nend"

            {:manual, line, suggestion}

          _ ->
            {:manual, line,
             "Replace `with pattern <- expr do ... end` with `case expr do pattern -> ...; error -> error end`"}
        end
    end
  end

  defp infer_error_clause(pattern) do
    cond do
      String.starts_with?(pattern, "{:ok") -> "{:error, _} = error -> error"
      String.starts_with?(pattern, ":ok") -> "{:error, _} = error -> error"
      String.starts_with?(pattern, "{:error") -> "{:ok, _} = ok -> ok"
      true -> "other -> other"
    end
  end
end
