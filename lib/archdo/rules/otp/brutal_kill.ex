defmodule Archdo.Rules.OTP.BrutalKill do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.39"

  @impl true
  def description,
    do: "Process.exit(pid, :kill) bypasses terminate/2 — use :shutdown for graceful stop"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_brutal_kills(file, ast)
    end
  end

  defp find_brutal_kills(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, [:Process]}, :exit]}, _, [_pid, kill_reason]} ->
          kill_atom?(kill_reason)

        _ ->
          false
      end),
      fn {_, meta, _} ->
        Diagnostic.warning("5.39",
          title: "Brutal process kill",
          message: "Process.exit(pid, :kill) bypasses terminate/2 — data may be lost",
          why:
            ":kill is an untrappable signal — the target process dies immediately without running " <>
              "terminate/2. Any in-flight work, open file handles, or pending writes are lost. " <>
              "Use {:shutdown, reason} or :shutdown instead, which allows the process to clean up " <>
              "gracefully. Reserve :kill for truly stuck processes that don't respond to :shutdown.",
          alternatives: [
            Fix.new(
              summary: "Use :shutdown or {:shutdown, reason} for graceful termination",
              detail:
                "Process.exit(pid, :shutdown) triggers terminate/2 in the target process, " <>
                  "allowing it to flush queues, close connections, and save state.",
              applies_when: "The process should clean up before dying (almost always)."
            ),
            Fix.new(
              summary: "Use GenServer.stop/3 or Supervisor.terminate_child/2",
              detail:
                "Higher-level APIs that handle shutdown properly. GenServer.stop sends a " <>
                  ":shutdown exit. Supervisor.terminate_child respects the child's shutdown spec.",
              applies_when: "The process is a GenServer or supervised child."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.39"],
          context: %{},
          file: file,
          line: AST.line(meta)
        )
      end
    )
  end

  defp kill_atom?({:__block__, _, [:kill]}), do: true
  defp kill_atom?(:kill), do: true
  defp kill_atom?(_), do: false
end
