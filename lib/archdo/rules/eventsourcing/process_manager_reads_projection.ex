defmodule Archdo.Rules.EventSourcing.ProcessManagerReadsProjection do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "8.7"

  @impl true
  def description, do: "Process manager state must come from events, not from projection reads"

  @impl true
  def analyze(file, ast, _opts) do
    case process_manager_module?(ast) do
      false -> []
      true -> find_repo_reads(file, ast)
    end
  end

  defp find_repo_reads(file, ast) do
    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, _} ->
        List.last(mod_parts) == :Repo and func in [:get, :get!, :get_by, :get_by!, :one, :one!, :all]

      _ ->
        false
    end)
    |> Enum.uniq_by(fn {_, meta, _} -> AST.line(meta) end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
      call = "#{Enum.join(mod_parts, ".")}.#{func}"
      module_name = AST.extract_module_name(ast)

      Diagnostic.warning("8.7",
        title: "Process manager reads from a projection",
        message: "Process manager #{module_name} calls #{call} to read database state",
        why:
          "Process managers must derive their state from the events they have observed, via `apply/2`. Reading " <>
            "from a projection means decisions depend on a read model that may not yet have caught up — leading to " <>
            "race conditions during replay and after restarts, plus invisible coupling to the projector's lifecycle.",
        alternatives: [
          Fix.new(
            summary: "Capture the data on an event the process manager already subscribes to",
            detail:
              "Identify the event that carries the information you currently fetch from the Repo, and add the " <>
                "field to the event payload. Update `apply/2` to store it in the process manager state and read " <>
                "from state in your `handle/2` clauses.",
            applies_when: "The data exists on (or can be added to) an event already in the workflow."
          ),
          Fix.new(
            summary: "Subscribe the process manager to a new event that publishes the data",
            detail:
              "If no existing event carries the value, emit a new event from the producing aggregate or " <>
                "context (e.g. `LimitConfigured`). The process manager subscribes, stores the value via " <>
                "`apply/2`, and stops needing the projection.",
            applies_when: "No existing event carries the data, but you control the producer."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#8.7"],
        context: %{module: module_name, call: call},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp process_manager_module?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Commanded, :ProcessManagers, :ProcessManager]} | _]} -> true
      _ -> false
    end)
  end
end
