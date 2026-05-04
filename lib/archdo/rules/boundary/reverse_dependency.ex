defmodule Archdo.Rules.Boundary.ReverseDependency do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — boundary rule consumes Archdo.Phoenix layer
  # classification rather than re-deriving "is this an application supervisor /
  # operational tool / web file?" via local heuristics. M1 carve-out for
  # operational code.

  alias Archdo.{AST, Diagnostic, Fix, Phoenix}

  @impl true
  def id, do: "1.26"

  @impl true
  def description, do: "Domain modules must not reference web layer modules"

  # Layers whose code legitimately bridges architectural boundaries.
  @bridge_layers [:application_root, :operational, :test]

  @impl true
  def analyze(file, ast, opts) do
    classification = Phoenix.resolve_classification(opts, file, ast)

    cond do
      classification.layer in @bridge_layers -> []
      web_layer?(classification.layer) -> []
      domain_file?(file) -> find_web_references(file, ast)
      true -> []
    end
  end

  defp web_layer?(layer) do
    layer in [:web, :live_view, :component, :controller, :router]
  end

  defp domain_file?(file) do
    (String.contains?(file, "/lib/") or String.starts_with?(file, "lib/")) and
      not (String.contains?(file, "_web/") or String.ends_with?(file, "_web.ex"))
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

  # A "web module" lives in a `*Web` namespace segment — e.g. `LivebookWeb.X`,
  # `MyAppWeb.Endpoint`, `MyApp.Web.Foo`. The discriminator is namespace-tail
  # match, not substring: `Livebook.Teams.WebSocket` is NOT a web module
  # (the segment `WebSocket` ends with "Socket"). BUG-10 from Livebook.
  defp web_module?(parts) when is_list(parts) do
    Enum.any?(parts, fn
      part when is_atom(part) -> web_namespace_segment?(Atom.to_string(part))
      _ -> false
    end)
  end

  defp web_namespace_segment?("Web"), do: true
  defp web_namespace_segment?(segment), do: String.ends_with?(segment, "Web")

  defp build_diagnostic(file, meta, parts, kind) do
    module_name = Enum.map_join(parts, ".", &to_string/1)

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
