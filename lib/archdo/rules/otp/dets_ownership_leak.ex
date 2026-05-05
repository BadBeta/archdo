defmodule Archdo.Rules.OTP.DetsOwnershipLeak do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.47"

  @impl true
  def description,
    do: "DETS table opened in GenServer without :dets.close in terminate/2"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> check_dets_cleanup(file, ast)
    end
  end

  defp check_dets_cleanup(file, ast) do
    case AST.genserver_module?(ast) do
      false -> []
      true -> maybe_flag(file, ast)
    end
  end

  defp maybe_flag(file, ast) do
    case opens_dets?(ast) and not has_terminate?(ast) do
      true -> [build_diagnostic(file, ast)]
      false -> []
    end
  end

  defp opens_dets?(ast) do
    AST.contains?(ast, fn
      {{:., _, [:dets, :open_file]}, _, _} -> true
      _ -> false
    end)
  end

  defp has_terminate?(ast) do
    AST.contains?(ast, fn
      {:def, _, [{:terminate, _, _} | _]} -> true
      _ -> false
    end)
  end

  defp build_diagnostic(file, ast) do
    module_name = AST.extract_module_name(ast)

    Diagnostic.warning("5.47",
      title: "DETS table without cleanup",
      message: "#{module_name} opens a DETS table but has no terminate/2 to close it",
      why:
        "DETS tables are on-disk files. Unlike ETS, the file persists when the owning " <>
          "process exits — but the file's internal state (in-flight buffer, dirty pages) " <>
          "is only flushed on `:dets.close/1`. A supervisor-restarted GenServer that " <>
          "opens the same file may face a corrupted-file recovery (`auto_repair`), data " <>
          "loss for unflushed writes, or an `:error, :system_limit` if the previous handle " <>
          "wasn't closed. Always close DETS in terminate/2.",
      alternatives: [
        Fix.new(
          summary: "Add terminate/2 that closes the DETS table",
          detail:
            "```elixir\n" <>
              "def terminate(_reason, %{table: table}) do\n" <>
              "  :dets.close(table)\n" <>
              "  :ok\n" <>
              "end\n" <>
              "```\n" <>
              "Set `Process.flag(:trap_exit, true)` in init/1 so terminate runs on " <>
              "supervisor shutdown.",
          applies_when: "The DETS handle is held by this GenServer."
        ),
        Fix.new(
          summary: "Use ETS instead if persistence isn't required",
          detail:
            "ETS is in-memory and ~10–100× faster than DETS for the same workload. " <>
              "If your data doesn't need to survive a node restart, ETS is the right " <>
              "choice and the cleanup story is automatic (table dies with the owner).",
          applies_when: "Persistence isn't a hard requirement."
        ),
        Fix.new(
          summary: "Configure auto_save to a small interval",
          detail:
            "DETS's default `auto_save: 180_000` (3 minutes) means up to 3 minutes of " <>
              "writes can be lost on crash. If terminate/2 isn't always reached " <>
              "(brutal_kill, OOM), set `auto_save: 5_000` or call `:dets.sync/1` " <>
              "after each batch.",
          applies_when: "Writes are infrequent enough to sync on demand."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.47"],
      context: %{module: module_name},
      file: file,
      line: 1
    )
  end
end
