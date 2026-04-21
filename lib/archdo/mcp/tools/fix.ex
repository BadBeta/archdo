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
    case File.exists?(file) do
      true ->
        rule_filter =
          case Map.get(args, "rule_id") do
            nil -> @fixable_rules
            id -> [id]
          end

        diagnostics = Runner.analyze([file], only: rule_filter)
        fixable = Enum.filter(diagnostics, &(&1.rule_id in @fixable_rules))

        case File.read(file) do
          {:ok, content} ->
            lines = String.split(content, "\n")

            fixes =
              fixable
              |> Enum.map(fn d -> generate_fix(d, lines) end)
              |> Enum.reject(&is_nil/1)

            {:ok, %{
              file: file,
              fixable_count: length(fixes),
              total_findings: length(diagnostics),
              fixes: fixes
            }}

          {:error, reason} ->
            {:error, "Cannot read #{file}: #{reason}"}
        end

      false ->
        {:error, "File not found: #{file}"}
    end
  end

  def call(_), do: {:error, "Missing required argument: file"}

  # Generate a fix suggestion with original and replacement code
  defp generate_fix(%{rule_id: "6.41", line: line}, lines) do
    # Single-clause with → case
    # Read the with block to suggest replacement
    case Enum.at(lines, line - 1) do
      nil -> nil
      original_line ->
        %{
          rule_id: "6.41",
          line: line,
          description: "Single-clause `with` — replace with `case`",
          original: String.trim(original_line),
          suggestion: "Replace `with {:ok, val} <- expr do ... end` with `case expr do {:ok, val} -> ...; {:error, _} = err -> err end`",
          auto_fixable: false
        }
    end
  end

  defp generate_fix(%{rule_id: "4.27", line: line}, lines) do
    case Enum.at(lines, line - 1) do
      nil -> nil
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
      nil -> nil
      original_line ->
        trimmed = String.trim(original_line)
        # Try to generate replacement
        replacement = String.replace(trimmed, ~r/Enum\.at\(([^,]+),\s*0\)/, "hd(\\1)")

        case replacement == trimmed do
          true -> nil
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
  defp generate_fix(%{rule_id: "6.33", title: "Code slop: single-step pipeline" <> _, line: line}, lines) do
    case Enum.at(lines, line - 1) do
      nil -> nil
      original_line ->
        trimmed = String.trim(original_line)

        case rewrite_single_pipe(trimmed) do
          nil -> nil
          ^trimmed -> nil
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
      nil -> nil
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
  defp rewrite_single_pipe(line) do
    case Regex.run(~r/^(.+?)\s*\|>\s*(.+)$/, line) do
      [_, input, call] ->
        input = String.trim(input)

        case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_.]*(?:\.[a-z_][a-z0-9_!?]*)?)\((.*)\)$/s, call) do
          [_, func_name, existing_args] ->
            new_args =
              case String.trim(existing_args) do
                "" -> input
                args -> "#{input}, #{args}"
              end

            "#{func_name}(#{new_args})"

          _ ->
            case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_.]*(?:\.[a-z_][a-z0-9_!?]*)?)$/, String.trim(call)) do
              [_, func_name] -> "#{func_name}(#{input})"
              _ -> nil
            end
        end

      _ ->
        nil
    end
  end
end
