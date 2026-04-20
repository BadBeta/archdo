defmodule Archdo.Rules.Module.LibConfigViaArgs do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "3.3"

  @impl true
  def description, do: "Libraries must accept configuration as arguments, not Application.get_env"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or application_module?(ast) or config_module?(file, ast) do
      []
    else
      find_app_get_env(file, ast)
    end
  end

  defp find_app_get_env(file, ast) do
    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, [:Application]}, func]}, _, _}
      when func in [:get_env, :fetch_env, :fetch_env!] ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, _}, func]}, meta, _} ->
      Diagnostic.warning("3.3",
        title: "Library reads Application config directly",
        message: "Module calls Application.#{func} to load configuration",
        why:
          "Reading from Application env couples the module to a global, untyped key-value store and makes " <>
            "tests order-dependent and flaky (because the config is process-global). It also forces every " <>
            "consumer of this code to be a Mix application — libraries that pull this in inherit the same " <>
            "configuration assumptions whether they want them or not.",
        alternatives: [
          Fix.new(
            summary: "Accept the config as start_link/init arguments",
            detail:
              "Move the Application.get_env to the supervisor (or wherever the process is started) and pass " <>
                "the resolved value through the child_spec opts. The module receives plain data and can be " <>
                "tested with whatever inputs you want.",
            example: """
            ```elixir
            # in supervisor:
            {MyServer, base_url: Application.fetch_env!(:my_app, :base_url)}

            # in MyServer:
            def start_link(opts) do
              GenServer.start_link(__MODULE__, opts, name: __MODULE__)
            end
            ```
            """,
            applies_when: "The module is a process or has a clear startup path."
          ),
          Fix.new(
            summary: "Accept the config as function arguments",
            detail:
              "If the module is a plain function library, take the values as parameters with sensible " <>
                "defaults. Callers can override per-call and tests get full control over inputs.",
            applies_when: "The module is a stateless library."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#3.3"],
        context: %{call: "Application.#{func}"},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp application_module?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Application]} | _]} -> true
      {:def, _, [{:start, _, [_, _]} | _]} -> true
      _ -> false
    end)
  end

  defp config_module?(file, ast) do
    String.ends_with?(file, "/config.ex") or
      String.contains?(file, "/config/") or
      AST.contains?(ast, fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} ->
          name = Atom.to_string(List.last(aliases))
          name in ["Config", "Configuration", "Settings"]
        _ -> false
      end)
  end

end
