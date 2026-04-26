defmodule Archdo.Rules.Testing.MissingTestCleanup do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.19"

  @impl true
  def description, do: "Test starts processes without on_exit cleanup — causes test pollution"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_unclean_process_starts(file, ast)
    end
  end

  defp find_unclean_process_starts(file, ast) do
    starts_process =
      AST.contains?(ast, fn
        {{:., _, [{:__aliases__, _, [:GenServer]}, :start_link]}, _, _} -> true
        {{:., _, [{:__aliases__, _, [:GenServer]}, :start]}, _, _} -> true
        {:start_link, _, _} -> true
        {{:., _, [{:__aliases__, _, [:Task]}, :start]}, _, _} -> true
        _ -> false
      end)

    has_start_supervised =
      AST.contains?(ast, fn
        {:start_supervised!, _, _} -> true
        {:start_supervised, _, _} -> true
        _ -> false
      end)

    has_on_exit =
      AST.contains?(ast, fn
        {:on_exit, _, _} -> true
        _ -> false
      end)

    if starts_process and not has_start_supervised and not has_on_exit do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.info("7.19",
          title: "Test starts process without cleanup",
          message:
            "#{module_name} starts processes directly without start_supervised!/1 or on_exit/1",
          why:
            "Processes started with GenServer.start_link or Task.start in tests outlive the " <>
              "test case if not cleaned up. They may interfere with subsequent tests, hold " <>
              "database connections, or cause port/name conflicts. start_supervised!/1 " <>
              "auto-stops the process when the test ends. on_exit/1 runs cleanup regardless " <>
              "of test pass/fail.",
          alternatives: [
            Fix.new(
              summary: "Use start_supervised!/1 instead of direct start_link",
              detail:
                "`pid = start_supervised!({MyServer, opts})` — automatically stopped after test.",
              applies_when: "Starting a GenServer or supervised process in a test."
            ),
            Fix.new(
              summary: "Add on_exit/1 to stop the process",
              detail:
                "```elixir\n" <>
                  "setup do\n" <>
                  "  {:ok, pid} = MyServer.start_link(opts)\n" <>
                  "  on_exit(fn -> GenServer.stop(pid) end)\n" <>
                  "  %{pid: pid}\n" <>
                  "end\n" <>
                  "```",
              applies_when: "start_supervised! doesn't fit (e.g., non-standard start)."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#7.19"],
          context: %{module: module_name},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end
end
