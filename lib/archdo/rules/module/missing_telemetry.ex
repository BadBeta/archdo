defmodule Archdo.Rules.Module.MissingTelemetry do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.19"

  @impl true
  def description, do: "Context facade modules should have telemetry instrumentation"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: find context facade modules and check for telemetry calls.
  A context facade is a file at `lib/app/foo.ex` that has a corresponding
  `lib/app/foo/` directory (indicating it's the public API for that context).
  """
  def analyze_project(file_asts) do
    # Build a set of directories that have sub-modules
    dirs_with_children =
      file_asts
      |> Enum.map(fn {file, _} -> Path.dirname(file) end)
      |> MapSet.new()

    file_asts
    |> Enum.filter(fn {file, _} -> context_facade?(file, dirs_with_children) end)
    |> Enum.flat_map(fn {file, ast} -> check_telemetry(file, ast) end)
  end

  defp context_facade?(file, dirs_with_children) do
    # A context facade is lib/app/context.ex where lib/app/context/ exists
    # Skip test files, web files, application.ex, etc.
    not excluded?(file) and
      String.ends_with?(file, ".ex") and
      (String.contains?(file, "/lib/") or String.starts_with?(file, "lib/")) and
      MapSet.member?(dirs_with_children, Path.rootname(file))
  end

  defp check_telemetry(file, ast) do
    public_fns = AST.extract_functions(ast, :public)
    fn_count = length(public_fns)

    cond do
      fn_count < 2 -> []
      has_telemetry_call?(ast) -> []
      true ->
        module_name = AST.extract_module_name(ast)

        [
          Diagnostic.info("4.19",
            title: "Context facade missing telemetry instrumentation",
            message:
              "#{module_name} has #{fn_count} public functions but no " <>
                ":telemetry.execute or :telemetry.span calls",
            why:
              "Context facades are the primary entry points for business operations. " <>
                "Without telemetry, you have no visibility into latency, throughput, or " <>
                "error rates at the business-operation level. Dashboards, alerting, and " <>
                "debugging all depend on instrumentation at this layer.",
            alternatives: [
              Fix.new(
                summary: "Add :telemetry.span/3 around key public functions",
                detail:
                  "Wrap each public function body in `:telemetry.span([:my_app, :context, :action], " <>
                    "%{}, fn -> {result, %{}} end)`. This emits start/stop/exception events " <>
                    "that dashboards and alerting can consume.",
                applies_when: "The module handles business operations worth monitoring."
              ),
              Fix.new(
                summary: "Add :telemetry.execute/3 for event-based instrumentation",
                detail:
                  "Call `:telemetry.execute([:my_app, :context, :action], %{duration: dt}, %{})` " <>
                    "at the end of functions. Lighter than span but requires manual timing.",
                applies_when: "Only specific operations need monitoring."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#4.19"],
            context: %{module: module_name, public_fn_count: fn_count},
            file: file,
            line: 1
          )
        ]
    end
  end

  defp has_telemetry_call?(ast) do
    AST.contains?(ast, fn
      # :telemetry.execute(...) or :telemetry.span(...) — bare atom
      {{:., _, [:telemetry, func]}, _, _} when func in [:execute, :span] -> true
      # :telemetry wrapped by literal_encoder as {:__block__, _, [:telemetry]}
      {{:., _, [{:__block__, _, [:telemetry]}, func]}, _, _}
      when func in [:execute, :span] -> true
      # Telemetry.execute(...) via alias
      {{:., _, [{:__aliases__, _, aliases}, func]}, _, _}
      when func in [:execute, :span] ->
        List.last(aliases) == :Telemetry
      _ -> false
    end)
  end

  defp excluded?(file) do
    String.contains?(file, "/test/") or
      String.starts_with?(file, "test/") or
      String.contains?(file, "_web/") or
      String.contains?(file, "/web/") or
      String.ends_with?(file, "/application.ex") or
      String.ends_with?(file, "/telemetry.ex") or
      String.ends_with?(file, "/repo.ex") or
      String.ends_with?(file, "/mailer.ex") or
      String.contains?(file, "/mix/")
  end
end
