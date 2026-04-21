defmodule Archdo.Rules.Testing.AssertOnImplementation do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.27"

  @impl true
  def description, do: "Tests assert on GenServer internal state rather than observable behavior"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_state_assertions(file, ast)
    end
  end

  defp find_state_assertions(file, ast) do
    sys_get_state_diagnostics = find_sys_get_state(file, ast)
    agent_get_identity_diagnostics = find_agent_get_identity(file, ast)

    sys_get_state_diagnostics ++ agent_get_identity_diagnostics
  end

  defp find_sys_get_state(file, ast) do
    ast
    |> AST.find_all(fn
      {{:., _, [:sys, :get_state]}, _, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta), ":sys.get_state/1")
    end)
  end

  defp find_agent_get_identity(file, ast) do
    ast
    |> AST.find_all(fn
      # Agent.get(pid, & &1) or Agent.get(pid, fn state -> state end)
      {{:., _, [{:__aliases__, _, [:Agent]}, :get]}, _, [_, callback]} ->
        identity_callback?(callback)

      _ ->
        false
    end)
    |> Enum.map(fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta), "Agent.get with identity function")
    end)
  end

  defp identity_callback?({:&, _, [{:&, _, [1]}]}), do: true
  defp identity_callback?({:fn, _, [{:->, _, [[{_, _, _}], {name, _, ctx}]}]})
       when is_atom(name) and is_atom(ctx), do: true
  defp identity_callback?(_), do: false

  defp build_diagnostic(file, line, pattern) do
    Diagnostic.info("7.27",
      title: "Assert on implementation detail",
      message: "Test uses #{pattern} to inspect internal process state",
      why:
        "Asserting on GenServer or Agent internal state couples tests to implementation details. " <>
          "If the state shape changes (e.g., from a map to a struct, or field rename), the tests " <>
          "break even though the behavior is identical. Test observable behavior instead: the return " <>
          "values of client API functions, messages sent, or side effects produced.",
      alternatives: [
        Fix.new(
          summary: "Assert on the client API return value instead",
          detail:
            "Instead of `:sys.get_state(pid)` and checking fields, call the GenServer's " <>
              "public client function and assert on its return value. If there is no client " <>
              "function that exposes the information, the state detail may not need testing.",
          applies_when: "The GenServer has a client API that exposes the relevant state."
        ),
        Fix.new(
          summary: "Assert on observable side effects",
          detail:
            "If the test verifies that an event was processed, assert on the observable " <>
              "outcome: a message sent, a database record created, or a PubSub broadcast. " <>
              "These survive internal refactors.",
          applies_when: "The state change triggers an observable side effect."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#7.27"],
      context: %{pattern: pattern},
      file: file,
      line: line
    )
  end
end
