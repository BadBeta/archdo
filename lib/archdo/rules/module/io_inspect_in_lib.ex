defmodule Archdo.Rules.Module.IoInspectInLib do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.53"

  @impl true
  def description,
    do: "IO.inspect or dbg in lib/ — debug-print left in production code"

  @impl true
  def cleanup_pass, do: 5

  @impl true
  def analyze(file, ast, _opts) do
    case in_scope?(file) do
      true -> AST.prewalk_collect(file, ast, &collect/3)
      false -> []
    end
  end

  # Scope: production lib/ code only. Tests, scripts, priv/, mix.exs are out.
  defp in_scope?(file) do
    not AST.test_file?(file) and
      not String.starts_with?(file, "priv/") and
      not String.contains?(file, "/priv/") and
      not String.starts_with?(file, "scripts/") and
      file != "mix.exs"
  end

  # §§ elixir-implementing: §5.2 — multi-clause head, no if/else.

  # IO.inspect(value) and IO.inspect(value, opts) — alias form
  defp collect(
         {{:., _, [{:__aliases__, _, [:IO]}, :inspect]}, meta, args} = node,
         acc,
         file
       )
       when is_list(args) do
    {node, [diag(:io_inspect, file, meta) | acc]}
  end

  # Kernel.dbg(...) — alias form
  defp collect(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :dbg]}, meta, _args} = node,
         acc,
         file
       ) do
    {node, [diag(:dbg, file, meta) | acc]}
  end

  # dbg(value) — bare auto-imported Kernel form
  defp collect({:dbg, meta, args} = node, acc, file) when is_list(args) do
    {node, [diag(:dbg, file, meta) | acc]}
  end

  defp collect(node, acc, _file), do: {node, acc}

  defp diag(kind, file, meta) do
    {title, name} =
      case kind do
        :io_inspect -> {"IO.inspect in lib/", "IO.inspect"}
        :dbg -> {"dbg in lib/", "dbg"}
      end

    Diagnostic.warning("5.53",
      title: title,
      message:
        "#{name} call left in production code under lib/. " <>
          "These are debug-print primitives — they don't belong in shipped code.",
      why:
        "#{name} writes to stdio on every call, which (a) leaks internal state to " <>
          "production logs (often unredacted), (b) bypasses the project's structured-" <>
          "logging conventions, and (c) usually indicates the call was added during " <>
          "debugging and forgotten. Use Logger with structured metadata for " <>
          "anything that should ship.",
      alternatives: [
        Fix.new(
          summary: "Replace with structured Logger",
          detail:
            "Use `Logger.debug/info/warning/error` with metadata: " <>
              "`Logger.info(\"computed value\", value: v)`. Structured metadata " <>
              "is searchable in log aggregators and respects log-level config.",
          applies_when: "The output is genuinely useful in production."
        ),
        Fix.new(
          summary: "Remove the call",
          detail:
            "If this was added for local debugging, delete it. Add a " <>
              "`# RULE-EXCEPTION: 5.53 reason: <why>` comment if the call must " <>
              "stay (e.g., a CLI tool whose `IO.inspect` is the user-visible output).",
          applies_when:
            "The call was added during debugging and shipping the output is unintended."
        )
      ],
      tags: [:slop, :observability],
      file: file,
      line: AST.line(meta)
    )
  end
end
