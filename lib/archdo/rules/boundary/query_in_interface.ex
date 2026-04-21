defmodule Archdo.Rules.Boundary.QueryInInterface do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.28"

  @impl true
  def description, do: "Ecto.Query building in interface layer — queries belong in context modules"

  @impl true
  def analyze(file, ast, _opts) do
    case interface_file?(file) do
      true -> find_query_building(file, ast)
      false -> []
    end
  end

  defp find_query_building(file, ast) do
    Enum.map(AST.find_all(ast, fn
      # import Ecto.Query
      {:import, _, [{:__aliases__, _, aliases} | _]} ->
        alias_ends_with?(aliases, :Query)

      # from(u in User, ...)
      {:from, _, _} -> true

      # Ecto.Query.from(...)
      {{:., _, [{:__aliases__, _, aliases}, :from]}, _, _} ->
        alias_ends_with?(aliases, :Query)

      # where(query, ...) / select(query, ...) / join(query, ...) etc.
      {{:., _, [{:__aliases__, _, aliases}, func]}, _, _}
      when func in [:where, :select, :join, :preload, :order_by, :group_by, :having, :limit, :offset, :distinct] ->
        alias_ends_with?(aliases, :Query)

      _ ->
        false
    end), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  defp alias_ends_with?(aliases, target) when is_list(aliases) do
    case List.last(aliases) do
      ^target -> true
      _ -> false
    end
  end

  defp alias_ends_with?(_, _), do: false

  defp interface_file?(file) do
    String.contains?(file, "_controller.ex") or
      String.contains?(file, "/controllers/") or
      String.contains?(file, "_live.ex") or
      String.contains?(file, "/live/") or
      String.contains?(file, "_view.ex") or
      String.contains?(file, "/views/") or
      String.contains?(file, "_channel.ex") or
      String.contains?(file, "/channels/")
  end

  defp build_diagnostic(file, line) do
    Diagnostic.warning("1.28",
      title: "Ecto.Query in interface layer",
      message: "Query building in controller/LiveView/channel — move to a context module",
      why:
        "Ecto queries in the interface layer bypass the context boundary. " <>
          "The query logic gets duplicated across controllers, the context " <>
          "can't enforce business rules, and schema changes require updating " <>
          "the web layer. Queries belong in context modules.",
      alternatives: [
        Fix.new(
          summary: "Move the query to the owning context",
          detail:
            "Create a function in the context (e.g., `Accounts.list_users(filters)`) " <>
              "that encapsulates the query. The controller calls the context function.",
          applies_when: "Always — queries should not be built in the interface layer."
        )
      ],
      file: file,
      line: line
    )
  end
end
