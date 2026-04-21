defmodule Archdo.Rules.Testing.ProcessLeak do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.26"

  @impl true
  def description, do: "Processes started in tests without start_supervised! will leak on crash"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> find_leaked_processes(file, ast)
      false -> []
    end
  end

  defp find_leaked_processes(file, ast) do
    ast
    |> find_start_link_calls()
    |> Enum.reject(&inside_start_supervised?(ast, &1))
    |> Enum.map(&build_diagnostic(file, &1))
  end

  defp find_start_link_calls(ast) do
    AST.find_all(ast, fn
      # GenServer.start_link(...)
      {{:., _, [{:__aliases__, _, [:GenServer]}, :start_link]}, _, _} -> true
      # Supervisor.start_link(...)
      {{:., _, [{:__aliases__, _, [:Supervisor]}, :start_link]}, _, _} -> true
      # SomeModule.start_link(...)
      {{:., _, [{:__aliases__, _, _}, :start_link]}, _, _} -> true
      _ -> false
    end)
  end

  defp inside_start_supervised?(ast, target_node) do
    {_, target_meta, _} = extract_call_parts(target_node)
    target_line = AST.line(target_meta)

    # Find all start_supervised! calls and check if any wraps the target
    AST.contains?(ast, fn
      {:start_supervised!, _, args} when is_list(args) ->
        contains_start_link_at_line?(args, target_line)

      {{:., _, [{:__aliases__, _, [:ExUnit, :Callbacks]}, :start_supervised!]}, _, args}
      when is_list(args) ->
        contains_start_link_at_line?(args, target_line)

      _ ->
        false
    end)
  end

  defp extract_call_parts({{:., _, _} = dot, meta, args}), do: {dot, meta, args}
  defp extract_call_parts({_, meta, _} = node), do: {node, meta, []}

  defp contains_start_link_at_line?(args, target_line) do
    AST.contains?(args, fn
      {{:., meta, [{:__aliases__, _, _}, :start_link]}, _, _} ->
        AST.line(meta) == target_line

      _ ->
        false
    end)
  end

  defp build_diagnostic(file, node) do
    {_, meta, _} = extract_call_parts(node)

    Diagnostic.info("7.26",
      title: "Process started without start_supervised!",
      message: "start_link called directly in test — use start_supervised! instead",
      why:
        "Processes started with bare start_link in tests are linked to the test process. " <>
          "If the test crashes (assertion failure, timeout), the linked process may not be " <>
          "stopped cleanly, leaking into subsequent tests. ExUnit's start_supervised! " <>
          "registers the process with the test supervisor, ensuring it is stopped after " <>
          "each test regardless of outcome.",
      alternatives: [
        Fix.new(
          summary: "Use start_supervised! to manage the process lifecycle",
          detail:
            "Replace `MyModule.start_link(args)` with `start_supervised!({MyModule, args})`. " <>
              "ExUnit will stop the process after the test completes, even on crash.",
          example: """
          ```elixir
          # Instead of:
          {:ok, pid} = MyWorker.start_link(arg)

          # Use:
          pid = start_supervised!({MyWorker, arg})
          ```
          """,
          applies_when: "The process is started for testing purposes."
        ),
        Fix.new(
          summary: "Use start_supervised with {:ok, pid} pattern for error testing",
          detail:
            "If you need to test process start failures, use `start_supervised/1` (without !) " <>
              "which returns `{:ok, pid}` or `{:error, reason}`.",
          applies_when: "You need to assert on start failure."
        ),
        Fix.new(
          summary: "Add an on_exit callback to stop the process",
          detail:
            "If start_supervised! doesn't fit (e.g. the process isn't a child_spec-compatible " <>
              "module), use `on_exit(fn -> GenServer.stop(pid) end)` to ensure cleanup.",
          applies_when: "The process cannot be managed by start_supervised!."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#7.26"],
      context: %{},
      file: file,
      line: AST.line(meta)
    )
  end
end
