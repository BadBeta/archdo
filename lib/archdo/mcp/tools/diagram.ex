defmodule Archdo.Mcp.Tools.Diagram do
  @moduledoc false

  def name, do: "archdo_diagram"

  def description do
    "Generate architecture diagrams from compiled beam files. Returns Mermaid or SVG " <>
      "diagram source. Requires the target project to be compiled. " <>
      "Types: overview (context dependency map), modules (all module deps), " <>
      "context:Name (detail view of one context), blast:Module (blast radius), " <>
      "delta (AST vs compiled diff), system (SVG system architecture)."
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "project_path" => %{
          "type" => "string",
          "description" => "Path to the project root (where mix.exs lives)."
        },
        "type" => %{
          "type" => "string",
          "enum" => ["overview", "modules", "context", "blast", "delta", "system"],
          "description" => "Diagram type. Use 'overview' for architecture summary."
        },
        "target" => %{
          "type" => "string",
          "description" => "For 'context' and 'blast' types: the context or module name."
        }
      },
      "required" => ["project_path", "type"],
      "additionalProperties" => false
    }
  end

  def call(%{"project_path" => project_path, "type" => type} = args) do
    case Archdo.Compiled.analyze(project_path) do
      {:ok, graph} ->
        target = Map.get(args, "target")

        case generate(graph, type, target) do
          {:ok, diagram} -> {:ok, %{type: type, format: format_for(type), content: diagram}}
          {:error, _} = error -> error
        end

      {:error, reason} ->
        {:error,
         "Compiled analysis failed: #{reason}. Run `mix compile` in the target project first."}
    end
  end

  def call(_), do: {:error, "Missing required arguments: project_path, type"}

  defp generate(graph, "overview", _),
    do: {:ok, Archdo.Compiled.Diagram.architecture_overview(graph)}

  defp generate(graph, "modules", _),
    do: {:ok, Archdo.Compiled.Diagram.module_dependencies(graph)}

  defp generate(graph, "delta", _),
    do: {:ok, Archdo.Compiled.Diagram.dependency_delta(graph, ["lib"])}

  defp generate(graph, "system", _),
    do: {:ok, Archdo.Compiled.DiagramSystem.system_diagram(graph)}

  defp generate(_graph, "context", nil),
    do: {:error, "context type requires a 'target' argument (context name)"}

  defp generate(graph, "context", name),
    do: {:ok, Archdo.Compiled.Diagram.context_detail(graph, name)}

  defp generate(_graph, "blast", nil),
    do: {:error, "blast type requires a 'target' argument (module name)"}

  defp generate(graph, "blast", name) do
    module = String.to_atom("Elixir." <> name)
    {:ok, Archdo.Compiled.Diagram.blast_radius(graph, module)}
  end

  defp generate(_, type, _), do: {:error, "Unknown diagram type: #{type}"}

  defp format_for("system"), do: "svg"
  defp format_for(_), do: "mermaid"
end
