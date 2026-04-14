defmodule Archdo.Rules.OTP.EtsNoHeir do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.28"

  @impl true
  def description, do: "Critical ETS tables should configure :heir"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.genserver_module?(ast) do
      false ->
        []
      true ->
      find_ets_without_heir(file, ast)
    end
  end

  defp find_ets_without_heir(file, ast) do
    AST.find_all(ast, fn
      {{:., _, [:ets, :new]}, _meta, [_name, opts]} when is_list(opts) ->
        not has_heir_option?(opts)
      _ ->
        false
    end)
    |> Enum.map(fn {_, meta, _} ->
      Diagnostic.info("5.28",
        title: "ETS table without :heir",
        message: ":ets.new is called inside a GenServer without configuring an :heir",
        why:
          "An ETS table is owned by exactly one process — when that process dies, the table and all its data " <>
            "vanish. If a GenServer that owns a cache table crashes, the supervisor restarts it with an empty " <>
            "table, and the next request triggers a thundering herd against the underlying data source. " <>
            "Configuring an :heir lets the table survive the crash and be passed to the restarted process.",
        alternatives: [
          Fix.new(
            summary: "Add `{:heir, supervisor_pid, data}` to the table options",
            detail:
              "Set the supervising process as the heir. When the GenServer dies, ETS transfers ownership to " <>
                "the heir, which can hand it back to the restarted child via a `{:'ETS-TRANSFER', ...}` message.",
            applies_when: "You need the table to survive child restarts."
          ),
          Fix.new(
            summary: "Create the table in the supervisor (or Application start) instead",
            detail:
              "If the table should outlive every child of the supervisor, create it once in the supervisor's " <>
                "init/start callback (which doesn't crash often). Children just use the named table directly.",
            applies_when: "The table is logically owned by the supervisor, not the child."
          ),
          Fix.new(
            summary: "Accept the data loss if the table is cheap to rebuild",
            detail:
              "If the cached data is small and fast to repopulate (e.g. config from a local file), losing it " <>
                "on crash is fine. Document the choice in a moduledoc and add to the freeze baseline.",
            applies_when: "The cache is cheap to rebuild and the thundering herd risk is negligible."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.28"],
        context: %{},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp has_heir_option?(opts) do
    AST.contains?(opts, fn
      {:heir, _} -> true
      {:{}, _, [:heir | _]} -> true
      _ -> false
    end)
  end
end
