defmodule Archdo.Rules.Testing.RuntimeConfigForDi do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.16"

  @impl true
  def description, do: "Use Application.compile_env for dependency injection, not get_env at runtime"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or config_file?(file) or application_module?(ast) do
      []
    else
      find_runtime_di(file, ast)
    end
  end

  # Look for the anti-pattern: `Application.get_env(app, :key).some_function(...)`
  # This is runtime dispatch — slow, not compile-time safe, and not testable with Mox.
  # The `compile_env/3` pattern puts the module into a module attribute at compile time.
  defp find_runtime_di(file, ast) do
    AST.find_all(ast, fn
      # Pattern: Application.get_env(:my_app, :http_client).some_method(args)
      {{:., _, [{{:., _, [{:__aliases__, _, [:Application]}, :get_env]}, _, _}, _method]}, _, _} ->
        true

      # Pattern: client = Application.get_env(...) followed by client.fetch(...)
      # Harder to detect reliably, skip for now
      _ ->
        false
    end)
    |> Enum.map(fn {_, meta, _} ->
      Diagnostic.info("7.16",
        title: "Runtime DI via Application.get_env",
        message: "Application.get_env is used at runtime to dispatch into a swappable implementation",
        why:
          "Pulling the implementation from Application env on every call is slow (an Application lookup per " <>
            "call), not compile-time safe (a typo silently uses the default), and not friendly to Mox: tests " <>
            "have to set the env globally and remember to reset it. `Application.compile_env/3` reads the value " <>
            "once at compile time and pins it into a module attribute, which is faster and safer.",
        alternatives: [
          Fix.new(
            summary: "Use `Application.compile_env/3` and store the implementation in a module attribute",
            detail:
              "Replace the runtime lookup with `@http_client Application.compile_env(:my_app, :http_client, " <>
                "MyApp.HTTPClient.Impl)` at the top of the module. Calls become `@http_client.fetch(...)`. " <>
                "Tests configure the implementation per-environment and Mox can verify it.",
            example: """
            ```elixir
            @http_client Application.compile_env(:my_app, :http_client, MyApp.HTTPClient.Impl)

            def fetch(url), do: @http_client.fetch(url)
            ```
            """,
            applies_when: "The implementation is fixed at deploy time."
          ),
          Fix.new(
            summary: "Inject the implementation as a function argument",
            detail:
              "If the implementation needs to vary per call (multi-tenant, request-scoped), pass it as an " <>
                "explicit argument with a default. Tests pass their own implementation and there's no global state.",
            applies_when: "The implementation varies per call."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.16"],
        context: %{},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp config_file?(file) do
    String.contains?(file, "/config/") or String.ends_with?(file, "/config.ex")
  end

  defp application_module?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Application]} | _]} -> true
      _ -> false
    end)
  end
end
