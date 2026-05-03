defmodule Archdo.Rules.Module.ScatteredConfig do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "3.2"

  @impl true
  def description,
    do: "System.get_env and Application config calls scattered across business logic"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) or config_file?(file) or mix_file?(file) do
      true -> []
      false -> find_scattered_reads(file, ast)
    end
  end

  defp find_scattered_reads(file, ast) do
    ast
    |> AST.find_all(&scattered_call?/1)
    |> Enum.take(1)
    |> Enum.map(fn node ->
      meta = elem(node, 1)
      build_diagnostic(file, AST.line(meta), call_kind(node))
    end)
  end

  # §§ elixir-implementing: §5.2, §7.6 — multi-clause head dispatch on AST
  # shape. The shape predicate is split from the kind discriminator so the
  # find_all closure stays simple.
  defp scattered_call?({{:., _, [{:__aliases__, _, [:System]}, fun]}, _, _})
       when fun in [:get_env, :fetch_env, :fetch_env!],
       do: true

  defp scattered_call?({{:., _, [{:__aliases__, _, [:Application]}, fun]}, _, _})
       when fun in [:get_env, :fetch_env, :fetch_env!],
       do: true

  defp scattered_call?(_), do: false

  defp call_kind({{:., _, [{:__aliases__, _, [:System]}, _fun]}, _, _}), do: :system
  defp call_kind({{:., _, [{:__aliases__, _, [:Application]}, _fun]}, _, _}), do: :application

  # §§ elixir-planning: §10.5.1 — the centralized accessor lives in a
  # *_config.ex (e.g. lib/my_app/app_config.ex) or under config/. Reads
  # there are intentional. Path.starts_with?(file, "config/") catches the
  # bare-relative form Mix passes; the "/config/" check catches absolute
  # paths.
  defp config_file?(file) do
    String.starts_with?(file, "config/") or
      String.contains?(file, "/config/") or
      String.ends_with?(file, "_config.ex")
  end

  defp mix_file?(file) do
    String.ends_with?(file, "mix.exs") or String.contains?(file, "/mix/")
  end

  defp build_diagnostic(file, line, :system), do: build_system_diag(file, line)
  defp build_diagnostic(file, line, :application), do: build_application_diag(file, line)

  defp build_system_diag(file, line) do
    Diagnostic.warning("3.2",
      title: "Environment variable read in module code",
      message: "System.get_env/fetch_env is called from a runtime module",
      why:
        "When System.get_env is sprinkled across modules, the set of environment variables an application " <>
          "depends on is undocumented — you can only discover them by grepping. Centralizing reads in " <>
          "`config/runtime.exs` (or a dedicated *Config module) gives you one place to validate, document, " <>
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
      context: %{kind: :system_get_env},
      file: file,
      line: line
    )
  end

  defp build_application_diag(file, line) do
    Diagnostic.warning("3.2",
      title: "Application config read in business-logic module",
      message: "Application.get_env / Application.fetch_env! called from a non-Config module",
      why:
        "Scattered Application.get_env calls are an ambient-authority anti-pattern: " <>
          "the set of configurable values can only be discovered by grepping, tests " <>
          "have to mutate global state to swap them, and the dialyzer sees `any()` " <>
          "instead of the concrete type. Centralize every Application config read in " <>
          "a single MyApp.Config accessor module — every other module routes through it.",
      alternatives: [
        Fix.new(
          summary: "Move the read into a centralized MyApp.Config module",
          detail:
            "Create `lib/my_app/app_config.ex` defining a zero-arg accessor for the " <>
              "value (`def timeout_ms, do: Application.fetch_env!(:my_app, :timeout_ms)`). " <>
              "Every module that needs the value calls `MyApp.Config.timeout_ms()` instead.",
          applies_when: "The value is application configuration that several modules read."
        ),
        Fix.new(
          summary: "Use Application.compile_env at module top-level",
          detail:
            "If the value is truly fixed at compile time and never overridden in " <>
              "runtime.exs or tests, capture it once in a module attribute via " <>
              "`@timeout Application.compile_env(:my_app, :timeout, 5_000)`. Dialyzer " <>
              "then sees the concrete type and missing keys crash at compile time.",
          applies_when: "The value is compile-time-frozen, no runtime override, no test swap."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#3.2"],
      context: %{kind: :application_get_env},
      file: file,
      line: line
    )
  end
end
