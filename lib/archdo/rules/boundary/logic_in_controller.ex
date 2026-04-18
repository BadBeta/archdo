defmodule Archdo.Rules.Boundary.LogicInController do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @max_controller_action_nodes 300

  @impl true
  def id, do: "1.15"

  @impl true
  def description, do: "Controller actions with business logic — delegate to context modules"

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      controller_file?(file) -> check_controller_actions(file, ast)
      true -> []
    end
  end

  defp check_controller_actions(file, ast) do
    fns = AST.extract_functions(ast, :public)

    fns
    |> Enum.filter(fn {_name, arity, _, _, _} -> arity == 2 end)
    |> Enum.filter(fn {_name, _, _, _, body} ->
      body != nil and AST.ast_size(body) > @max_controller_action_nodes
    end)
    |> Enum.map(fn {name, arity, meta, _, body} ->
      size = AST.ast_size(body)

      Diagnostic.info("1.15",
        title: "Large controller action",
        message: "#{name}/#{arity} has #{size} AST nodes (limit: #{@max_controller_action_nodes}) — extract logic to a context",
        why:
          "Controllers should be thin dispatchers: receive params, call a context function, " <>
            "render a response. Business logic in controllers can't be reused from LiveViews, " <>
            "background jobs, or other contexts. It also can't be tested without HTTP plumbing.",
        alternatives: [
          Fix.new(
            summary: "Move business logic to a context module",
            detail:
              "Extract the logic into `MyApp.Accounts.create_user(params)` or similar. " <>
                "The controller becomes: receive params → call context → render response.",
            applies_when: "The action does more than param extraction and rendering."
          ),
          Fix.new(
            summary: "Extract multi-step logic into a service module",
            detail:
              "If the action orchestrates multiple contexts (create user + send email + " <>
                "log event), extract into a service/workflow module that the controller calls.",
            applies_when: "The action coordinates across multiple contexts."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#1.15"],
        context: %{function: "#{name}/#{arity}", size: size},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp controller_file?(file) do
    String.contains?(file, "_controller.ex") or
      String.contains?(file, "/controllers/")
  end
end
