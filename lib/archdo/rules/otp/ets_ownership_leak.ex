defmodule Archdo.Rules.OTP.EtsOwnershipLeak do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.40"

  @impl true
  def description, do: "ETS table created in GenServer without cleanup in terminate/2"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      case AST.genserver_module?(ast) do
        false -> []
        true -> check_ets_cleanup(file, ast)
      end
    end
  end

  defp check_ets_cleanup(file, ast) do
    creates_ets =
      AST.contains?(ast, fn
        {{:., _, [:ets, :new]}, _, _} -> true
        _ -> false
      end)

    has_terminate =
      AST.contains?(ast, fn
        {:def, _, [{:terminate, _, _} | _]} -> true
        _ -> false
      end)

    has_heir =
      AST.contains?(ast, fn
        {:heir, _, _} -> true
        {{:__block__, _, [:heir]}, _} -> true
        _ -> false
      end)

    if creates_ets and not has_terminate and not has_heir do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.info("5.40",
          title: "ETS table without cleanup",
          message:
            "#{module_name} creates an ETS table but has no terminate/2 to clean up",
          why:
            "When the owning process dies, its ETS tables are automatically deleted. But if the " <>
              "process is restarted by a supervisor, the new instance creates a fresh table — " <>
              "the data in the old table is lost silently. If the table is :named_table, the " <>
              "new :ets.new will crash because the name is still taken (race with cleanup). " <>
              "Implementing terminate/2 or configuring :heir ensures controlled handoff.",
          alternatives: [
            Fix.new(
              summary: "Add terminate/2 to delete the table explicitly",
              detail:
                "```elixir\n" <>
                  "def terminate(_reason, %{table: table}) do\n" <>
                  "  :ets.delete(table)\n" <>
                  "  :ok\n" <>
                  "end\n" <>
                  "```\n" <>
                  "Remember to set `Process.flag(:trap_exit, true)` in init/1.",
              applies_when: "The table data is disposable and can be rebuilt on restart."
            ),
            Fix.new(
              summary: "Configure :heir for table survival across restarts",
              detail:
                "Pass `{:heir, heir_pid, gift}` to :ets.new/2. When the owner dies, " <>
                  "the table transfers to the heir instead of being deleted.",
              applies_when: "The table data must survive process restarts."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.40"],
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
