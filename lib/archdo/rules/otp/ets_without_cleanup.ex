defmodule Archdo.Rules.OTP.EtsWithoutCleanup do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.45"

  @impl true
  def description, do: "Named ETS tables without cleanup leak on process restart"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_ets_without_cleanup(file, ast)
    end
  end

  defp find_ets_without_cleanup(file, ast) do
    named_ets_calls = find_named_ets_new(ast)

    case named_ets_calls do
      [] ->
        []

      [_ | _] ->
        has_terminate = has_terminate_callback?(ast)
        has_delete = has_ets_delete?(ast)

        case has_terminate or has_delete do
          true -> []
          false -> Enum.map(named_ets_calls, &build_diagnostic(file, &1))
        end
    end
  end

  defp find_named_ets_new(ast) do
    AST.find_all(ast, fn
      {{:., _, [:ets, :new]}, _, [_name, opts]} when is_list(opts) ->
        has_named_table_option?(opts)

      _ ->
        false
    end)
  end

  defp has_named_table_option?(opts) do
    Enum.any?(opts, fn
      :named_table -> true
      {:__block__, _, [:named_table]} -> true
      _ -> false
    end)
  end

  defp has_terminate_callback?(ast) do
    fns = AST.extract_functions(ast, :public)

    Enum.any?(fns, fn
      {:terminate, 2, _, _, _} -> true
      _ -> false
    end)
  end

  defp has_ets_delete?(ast) do
    AST.contains?(ast, fn
      {{:., _, [:ets, :delete]}, _, _} -> true
      _ -> false
    end)
  end

  defp build_diagnostic(file, {_, meta, _}) do
    Diagnostic.info("5.45",
      title: "Named ETS table without cleanup",
      message: ":ets.new with :named_table but no terminate/2 or :ets.delete found",
      why:
        "Named ETS tables are global resources identified by atom. When the owning process " <>
          "crashes and restarts, :ets.new will fail with :badarg because the table name is " <>
          "already taken (the old table persists until its owner dies, but with supervisors " <>
          "the restart can race). Without explicit cleanup in terminate/2, the restarted " <>
          "process cannot reclaim its table.",
      alternatives: [
        Fix.new(
          summary: "Add a terminate/2 callback that deletes the table",
          detail:
            "Implement `terminate/2` in the GenServer and call `:ets.delete(table_name)`. " <>
              "This ensures the table is cleaned up before the process exits, allowing a " <>
              "clean restart.",
          example: """
          ```elixir
          @impl true
          def terminate(_reason, %{table: table}) do
            :ets.delete(table)
            :ok
          end
          ```
          """,
          applies_when: "The process owns the ETS table and may restart."
        ),
        Fix.new(
          summary: "Use an ETS heir to transfer ownership on crash",
          detail:
            "Set `{:heir, pid, heir_data}` in the ETS options so the table is transferred " <>
              "to a stable process (e.g. the supervisor) on owner death. The restarted " <>
              "process can then reclaim it.",
          applies_when: "The table data should survive process restarts."
        ),
        Fix.new(
          summary: "Wrap ETS creation with a try to handle existing tables",
          detail:
            "Use `:ets.whereis(name)` to check if the table already exists before creating " <>
              "it, or rescue the :badarg from :ets.new. This is a workaround — prefer " <>
              "explicit cleanup or heir.",
          applies_when: "Quick fix when restructuring is not immediately feasible."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.45"],
      context: %{},
      file: file,
      line: AST.line(meta)
    )
  end
end
