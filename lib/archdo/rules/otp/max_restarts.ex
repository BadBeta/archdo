defmodule Archdo.Rules.OTP.MaxRestarts do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.6"

  @impl true
  def description, do: "Supervisors should explicitly set max_restarts/max_seconds"

  @impl true
  def analyze(file, ast, _opts) do
    find_supervisor_calls(file, ast)
  end

  defp find_supervisor_calls(file, ast) do
    AST.find_all(ast, fn
      # Supervisor.start_link(children, opts)
      {{:., _, [{:__aliases__, _, [:Supervisor]}, :start_link]}, _meta, _args} -> true
      # Supervisor.init(children, opts)
      {{:., _, [{:__aliases__, _, [:Supervisor]}, :init]}, _meta, _args} -> true
      # DynamicSupervisor.start_link(opts)
      {{:., _, [{:__aliases__, _, [:DynamicSupervisor]}, :start_link]}, _meta, _args} -> true
      _ -> false
    end)
    |> Enum.filter(fn {_, _, args} -> missing_restart_config?(args) end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, mod}, func]}, meta, _} ->
      call = "#{Enum.join(mod, ".")}.#{func}"

      Diagnostic.info("5.6",
        title: "Default supervisor restart budget",
        message: "#{call} relies on the default max_restarts: 3, max_seconds: 5",
        why:
          "Three restarts in five seconds is aggressive: a transient network blip that causes four rapid " <>
            "failures will exhaust the budget and kill the supervisor, then escalate to its parent. For " <>
            "children that depend on external services the default is almost always too tight, and the " <>
            "cascade is silent until the whole subtree dies.",
        alternatives: [
          Fix.new(
            summary: "Tune max_restarts/max_seconds based on the actual failure mode",
            detail:
              "Pick a budget that tolerates the expected blip frequency for this subtree. For external " <>
                "service consumers, `max_restarts: 10, max_seconds: 60` is a reasonable starting point; for " <>
                "purely local children the default is fine but should be made explicit so the choice is documented.",
            example: """
            ```elixir
            Supervisor.start_link(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
            ```
            """,
            applies_when: "Children depend on remote services or have intermittent failure modes."
          ),
          Fix.new(
            summary: "Move volatile children under a dedicated sub-supervisor",
            detail:
              "Isolate the failure-prone children under a separate Supervisor with its own (looser) restart " <>
                "budget. The parent supervisor keeps the conservative defaults for stable infrastructure.",
            applies_when: "Some children fail much more often than others."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.6"],
        context: %{call: call},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp missing_restart_config?(args) do
    # Check if the opts argument contains max_restarts
    opts = List.last(args)

    not contains_key?(opts, :max_restarts)
  end

  defp contains_key?(opts, key) when is_list(opts) do
    AST.contains?(opts, fn
      {^key, _} -> true
      {:{}, _, [^key | _]} -> true
      {:__block__, _, [^key]} -> true
      _ -> false
    end)
  end

  defp contains_key?(_, _), do: false
end
