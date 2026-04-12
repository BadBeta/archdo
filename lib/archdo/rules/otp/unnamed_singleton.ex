defmodule Archdo.Rules.OTP.UnnamedSingleton do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.33"

  @impl true
  def description, do: "GenServer intended as singleton but not registered with a name"

  @impl true
  def analyze(file, ast, _opts) do
    if not AST.genserver_module?(ast) do
      []
    else
      check_singleton_pattern(file, ast)
    end
  end

  # Heuristic: a GenServer whose public API uses __MODULE__ as the server
  # reference (e.g. GenServer.call(__MODULE__, ...)) is written as a singleton,
  # but if start_link doesn't pass `name: __MODULE__`, the name isn't registered
  # and the API calls will fail or hit a different process.
  defp check_singleton_pattern(file, ast) do
    uses_module_as_server? = calls_genserver_with_module?(ast)
    registers_name? = has_name_option?(ast)

    if uses_module_as_server? and not registers_name? do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.warning("5.33",
          title: "Singleton GenServer not name-registered",
          message:
            "#{module_name} addresses itself by `__MODULE__` in GenServer.call/cast but its start_link doesn't pass `name: __MODULE__`",
          why:
            "GenServer.call/cast(__MODULE__, ...) only works if the module is registered under its own name. " <>
              "Without `name: __MODULE__` on start_link, the call resolves to whatever (if anything) is registered " <>
              "as that atom — typically nothing — and crashes with `:noproc`. The bug only fires when the API " <>
              "is invoked, often only in production.",
          alternatives: [
            Fix.new(
              summary: "Add `name: __MODULE__` to start_link",
              detail:
                "If the GenServer is genuinely a singleton, pass `name: __MODULE__` so it registers under the " <>
                  "module name. The existing API functions then resolve correctly.",
              example: """
              ```elixir
              def start_link(args) do
                GenServer.start_link(__MODULE__, args, name: __MODULE__)
              end
              ```
              """,
              applies_when: "There is exactly one of these processes per node."
            ),
            Fix.new(
              summary: "Take a pid (or `:via` tuple) parameter and pass it through the API",
              detail:
                "If the process is one-per-tenant or one-per-something, take a `server` argument in the API " <>
                  "functions and pass it to `GenServer.call/cast`. Callers obtain the pid via Registry.",
              applies_when: "There can be more than one instance of this GenServer."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.33"],
          context: %{module: module_name},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp calls_genserver_with_module?(ast) do
    AST.contains?(ast, fn
      {{:., _, [{:__aliases__, _, [:GenServer]}, func]}, _, [{:__MODULE__, _, _} | _]}
      when func in [:call, :cast] ->
        true

      _ ->
        false
    end)
  end

  defp has_name_option?(ast) do
    # Look for `name: __MODULE__` (wrapped or not) inside a start_link call
    AST.contains?(ast, fn
      {:name, {:__MODULE__, _, _}} -> true
      {{:__block__, _, [:name]}, {:__MODULE__, _, _}} -> true
      _ -> false
    end)
  end
end
