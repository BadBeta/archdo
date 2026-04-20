defmodule Archdo.Rules.Compiled.RepoBypass do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Config, Diagnostic, Fix}
  alias Archdo.Compiled.Graph

  @impl true
  def id, do: "1.22"

  @impl true
  def description, do: "Module calls Repo directly instead of through owning context"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  # Repo function names that indicate data access
  @repo_functions ~w(
    get get! get_by get_by! one one! all
    insert insert! update update! delete delete!
    insert_all update_all delete_all
    transaction preload aggregate exists?
  )a

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{modules: modules, calls_by_module: calls_by_module} = _graph) do
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
        |> Enum.flat_map(fn caller_mod ->
          caller_calls = Map.get(calls_by_module, caller_mod, [])

          repo_calls =
            caller_calls
            |> Enum.filter(fn call ->
              callee_mod = elem(call.callee, 0)
              callee_fn = elem(call.callee, 1)

              MapSet.member?(repo_modules, callee_mod) and
                callee_fn in @repo_functions
            end)

          case repo_calls do
            [] ->
              []

            _ ->
              # Check if the caller IS a context boundary module
              # Context modules are allowed to call Repo
              case context_module?(caller_mod, config, project_modules) do
                true -> []
                false -> [build_diagnostic(caller_mod, repo_calls, config)]
              end
          end
        end)
    end
  end

  defp repo_module?(mod) do
    mod_str = Atom.to_string(mod)
    String.ends_with?(mod_str, ".Repo") or String.ends_with?(mod_str, "Repo")
  end

  defp interface_module?(mod, config) do
    mod_str = AST.module_name(mod)

    Config.classify_module(config, mod_str) == :interface or
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
      message:
        "#{caller_name} calls Repo directly: #{repo_fns}",
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
