defmodule Archdo.Rules.Compiled.RepoBypass do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Config, Diagnostic, Fix}
  alias Archdo.Compiled

  @interface_layer :interface

  @impl true
  def id, do: "1.22"

  @impl true
  def description, do: "Module calls Repo directly instead of through owning context"

  # Repo function names that indicate data access
  @repo_functions ~w(
    get get! get_by get_by! one one! all
    insert insert! update update! delete delete!
    insert_all update_all delete_all
    transaction preload aggregate exists?
  )a

  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    modules = Compiled.modules(graph)
    calls_by_module = Compiled.calls_by_module(graph)

    config = Config.load()
    project_modules = MapSet.new(Map.keys(modules))

    # Find all Repo modules in the project (modules ending in .Repo or named Repo)
    repo_modules =
      modules
      |> Map.keys()
      |> Enum.filter(&repo_module?/1)
      |> MapSet.new()

    case MapSet.size(repo_modules) do
      0 ->
        []

      _ ->
        # For each non-context, non-repo module, check if it calls Repo directly
        modules
        |> Map.keys()
        |> Enum.reject(fn mod ->
          MapSet.member?(repo_modules, mod) or
            interface_module?(mod, config) or
            migration_module?(mod)
        end)
        |> Enum.flat_map(&caller_diag(&1, calls_by_module, repo_modules, config, project_modules))
    end
  end

  defp caller_diag(caller_mod, calls_by_module, repo_modules, config, project_modules) do
    repo_calls =
      calls_by_module
      |> Map.get(caller_mod, [])
      |> Enum.filter(&repo_call?(&1, repo_modules))

    diag_for_repo_calls(repo_calls, caller_mod, config, project_modules)
  end

  defp repo_call?(call, repo_modules) do
    MapSet.member?(repo_modules, elem(call.callee, 0)) and
      elem(call.callee, 1) in @repo_functions
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the empty-list shape of repo_calls and on the context-module
  # exemption boolean.
  defp diag_for_repo_calls([], _caller_mod, _config, _project_modules), do: []

  defp diag_for_repo_calls(repo_calls, caller_mod, config, project_modules) do
    diag_unless_context(
      context_module?(caller_mod, config, project_modules),
      caller_mod,
      repo_calls,
      config
    )
  end

  defp diag_unless_context(true, _caller_mod, _repo_calls, _config), do: []

  defp diag_unless_context(false, caller_mod, repo_calls, config),
    do: [build_diagnostic(caller_mod, repo_calls, config)]

  defp repo_module?(mod) do
    mod_str = Atom.to_string(mod)
    String.ends_with?(mod_str, ".Repo") or String.ends_with?(mod_str, "Repo")
  end

  defp interface_module?(mod, config) do
    mod_str = AST.module_name(mod)

    Config.classify_module(config, mod_str) == @interface_layer or
      String.contains?(mod_str, "Controller") or
      String.contains?(mod_str, "Live.") or
      String.contains?(mod_str, "Channel")
  end

  defp migration_module?(mod) do
    mod_str = Atom.to_string(mod)
    String.contains?(mod_str, ".Migrations.") or String.contains?(mod_str, ".Migration")
  end

  # A context module is a top-level module within the app that serves
  # as a boundary. Heuristic: it's at the second level (App.Context)
  # and is not a child module (App.Context.Internal).
  defp context_module?(mod, config, _project_modules) do
    mod_str = AST.module_name(mod)

    case Config.classify_module(config, mod_str) do
      :domain ->
        # Domain modules at the context level (2 parts: App.Context) can call Repo
        parts = Module.split(mod)
        length(parts) == 2

      _ ->
        false
    end
  end

  defp build_diagnostic(caller_mod, repo_calls, _config) do
    caller_name = AST.module_name(caller_mod)

    repo_fns =
      repo_calls
      |> Enum.map(fn call ->
        callee_mod = AST.module_name(elem(call.callee, 0))
        callee_fn = elem(call.callee, 1)
        "#{callee_mod}.#{callee_fn}"
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join(", ")

    Diagnostic.warning("1.22",
      title: "Direct Repo access outside context",
      message: "#{caller_name} calls Repo directly: #{repo_fns}",
      why:
        "Compiled analysis confirms #{caller_name} calls Repo functions directly. " <>
          "Only context boundary modules should access the Repo — this ensures " <>
          "data access is encapsulated and business rules are enforced consistently. " <>
          "Direct Repo calls from non-context modules bypass validation, authorization, " <>
          "and any cross-cutting concerns the context provides.",
      alternatives: [
        Fix.new(
          summary: "Move the query to the owning context",
          detail:
            "Add a function to the appropriate context module that wraps the " <>
              "Repo call. #{caller_name} calls the context function instead.",
          applies_when: "The Repo call should go through a context."
        ),
        Fix.new(
          summary: "This IS a context — adjust module organization",
          detail:
            "If #{caller_name} is meant to be a context boundary, ensure it's " <>
              "at the top level of the domain (e.g., MyApp.Accounts, not MyApp.Accounts.Internal).",
          applies_when: "The module is misclassified."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.22"],
      context: %{
        caller: caller_name,
        repo_calls: repo_fns,
        call_count: length(repo_calls)
      },
      file: "lib",
      line: 0
    )
  end
end
