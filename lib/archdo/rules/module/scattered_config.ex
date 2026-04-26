defmodule Archdo.Rules.Module.ScatteredConfig do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "3.2"

  @impl true
  def description, do: "System.get_env should be in config/runtime.exs, not scattered in modules"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or config_file?(file) or mix_file?(file) do
      []
    else
      find_system_get_env(file, ast)
    end
  end

  defp find_system_get_env(file, ast) do
    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, [:System]}, func]}, _, _}
      when func in [:get_env, :fetch_env, :fetch_env!] ->
        true

      _ ->
        false
    end)
    |> Enum.take(1)
    |> Enum.map(fn {_, meta, _} ->
      Diagnostic.warning("3.2",
        title: "Environment variable read in module code",
        message: "System.get_env/fetch_env is called from a runtime module",
        why:
          "When System.get_env is sprinkled across modules, the set of environment variables an application " <>
            "depends on is undocumented — you can only discover them by grepping. Centralizing reads in " <>
            "`config/runtime.exs` (or a dedicated Config module) gives you one place to validate, document, " <>
            "and override config, and lets releases fail fast at boot if a required variable is missing.",
        alternatives: [
          Fix.new(
            summary: "Move the read into `config/runtime.exs`",
            detail:
              "Read the env var in runtime.exs, validate it (raise on missing if required), and store it via " <>
                "`config :my_app, :foo, value`. The runtime module then reads the validated value with " <>
                "`Application.fetch_env!/2`. Failures happen at boot, not on the first request.",
            applies_when: "The value is application configuration."
          ),
          Fix.new(
            summary: "Pass the value as an argument from the supervisor",
            detail:
              "If the value is local to one process (a credential, an endpoint URL), read it once in the " <>
                "supervisor that starts the process and pass it as part of `start_link` opts. The process " <>
                "stops depending on the environment entirely.",
            applies_when: "The value is needed by exactly one process."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#3.2"],
        context: %{},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp config_file?(file),
    do: String.contains?(file, "/config") or String.ends_with?(file, "_config.ex")

  defp mix_file?(file) do
    String.ends_with?(file, "mix.exs") or String.contains?(file, "/mix/")
  end
end
