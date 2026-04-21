defmodule Archdo.Rules.Boundary.ReverseDependency do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.26"

  @impl true
  def description, do: "Domain modules must not reference web layer modules"

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      web_file?(file) -> []
      domain_file?(file) -> find_web_references(file, ast)
      true -> []
    end
  end

  defp web_file?(file), do: String.contains?(file, "_web/")

  defp domain_file?(file) do
    (String.contains?(file, "/lib/") or String.starts_with?(file, "lib/")) and
      not web_file?(file)
  end

  defp find_web_references(file, ast) do
    find_web_aliases(file, ast) ++
      find_web_imports(file, ast) ++
      find_web_remote_calls(file, ast)
  end

  defp find_web_aliases(file, ast) do
    ast
    |> AST.find_all(fn
      {:alias, _, [{:__aliases__, _, parts} | _]} -> web_module?(parts)
      _ -> false
    end)
    |> Enum.map(fn {_, meta, [{:__aliases__, _, parts} | _]} ->
      build_diagnostic(file, meta, parts, :alias)
    end)
  end

  defp find_web_imports(file, ast) do
    ast
    |> AST.find_all(fn
      {:import, _, [{:__aliases__, _, parts} | _]} -> web_module?(parts)
      _ -> false
    end)
    |> Enum.map(fn {_, meta, [{:__aliases__, _, parts} | _]} ->
      build_diagnostic(file, meta, parts, :import)
    end)
  end

  defp find_web_remote_calls(file, ast) do
    ast
    |> AST.find_all(fn
      {{:., _, [{:__aliases__, _, parts}, _fun]}, _, _} -> web_module?(parts)
      _ -> false
    end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, parts}, _fun]}, meta, _} ->
      build_diagnostic(file, meta, parts, :remote_call)
    end)
  end

  defp web_module?(parts) when is_list(parts) do
    Enum.any?(parts, fn
      part when is_atom(part) -> part |> Atom.to_string() |> String.contains?("Web")
      _ -> false
    end)
  end

  defp build_diagnostic(file, meta, parts, kind) do
    module_name = parts |> Enum.map_join(".", &to_string/1)

    Diagnostic.warning("1.26",
      title: "Reverse dependency on web layer",
      message: "Domain module references web module #{module_name} via #{kind}",
      why:
        "Domain modules (business logic) should never depend on web layer modules. The dependency " <>
          "direction must flow inward: web → domain, never domain → web. When a domain module " <>
          "references a controller, view, or router helper, the domain becomes coupled to the web " <>
          "framework and cannot be tested, reused, or deployed independently.",
      alternatives: [
        Fix.new(
          summary: "Move the web-dependent logic to the web layer",
          detail:
            "If the domain module needs to trigger a web-layer action (e.g. building a URL), " <>
              "move that logic to a controller, LiveView, or web-layer helper that calls " <>
              "the domain module instead.",
          applies_when: "The domain module is doing web-layer work."
        ),
        Fix.new(
          summary: "Define a behaviour in the domain and implement it in the web layer",
          detail:
            "If the domain genuinely needs a capability that lives in the web layer, define " <>
              "a behaviour (port) in the domain and implement it (adapter) in the web layer. " <>
              "Inject the implementation via configuration or function arguments.",
          applies_when: "The domain needs to call back into the web layer."
        ),
        Fix.new(
          summary: "Use PubSub to decouple domain events from web reactions",
          detail:
            "If the domain needs to notify the web layer (e.g. broadcast a change), publish " <>
              "a domain event via PubSub. The web layer subscribes and reacts independently.",
          applies_when: "The domain is notifying the web layer of state changes."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.26"],
      context: %{kind: kind, web_module: module_name},
      file: file,
      line: AST.line(meta)
    )
  end
end
