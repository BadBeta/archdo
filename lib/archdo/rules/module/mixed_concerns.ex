defmodule Archdo.Rules.Module.MixedConcerns do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # Concerns that, when mixed in one module, suggest the module is doing too much
  @concerns %{
    web: [[:Phoenix, :Controller], [:Phoenix, :LiveView], [:Plug, :Conn]],
    persistence: [[:Ecto, :Repo], [:Ecto, :Query], [:Ecto, :Changeset]],
    http_client: [[:HTTPoison], [:Finch], [:Req], [:Tesla]],
    email: [[:Swoosh], [:Bamboo]],
    file_io: [[:File]],
    external_cloud: [[:ExAws], [:Stripe], [:Stripity]]
  }

  @max_concerns 2

  @impl true
  def id, do: "4.13"

  @impl true
  def description, do: "Mixed concerns — module touching too many distinct concern families"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or infrastructure_file?(file) do
      []
    else
      check_mixed_concerns(file, ast)
    end
  end

  defp check_mixed_concerns(file, ast) do
    touched =
      Enum.filter(Map.keys(@concerns), fn concern ->
        patterns = Map.get(@concerns, concern)

        Enum.any?(patterns, fn pattern ->
          module_is_used?(ast, pattern)
        end)
      end)

    if length(touched) > @max_concerns do
      module_name = AST.extract_module_name(ast)
      concern_list = touched |> Enum.map(&to_string/1) |> Enum.join(", ")

      [
        Diagnostic.info("4.13",
          title: "Module mixes multiple concern families",
          message: "#{module_name} touches #{length(touched)} distinct concern families: #{concern_list}",
          why:
            "A single module that touches web, persistence, HTTP clients, email, and file IO is doing the " <>
              "work of several modules. Each concern is a different reason to change, a different test setup, " <>
              "and a different deployment risk. Mixed concerns make refactoring harder (every change touches " <>
              "unrelated dependencies) and break the Single Responsibility heuristic at the file level.",
          alternatives: [
            Fix.new(
              summary: "Split the module along its concern boundaries",
              detail:
                "Identify which functions touch which concerns and extract them into separate modules — a " <>
                  "controller for web, a context for persistence, an adapter for HTTP. Each module has one " <>
                  "reason to change.",
              applies_when: "The concerns are clustered around distinct functions."
            ),
            Fix.new(
              summary: "Move some concerns into adapters/clients",
              detail:
                "If the concerns include external IO (HTTP, email, AWS), move those calls into adapter modules " <>
                  "and have this module depend on the adapters instead. The original module becomes orchestration " <>
                  "with one concern (calling adapters in the right order).",
              applies_when: "The mixed concerns are mostly external dependencies."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#4.13"],
          context: %{module: module_name, concerns: touched},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp module_is_used?(ast, pattern) do
    AST.contains?(ast, fn
      {{:., _, [{:__aliases__, _, parts}, _]}, _, _} ->
        List.starts_with?(parts, pattern)

      {:alias, _, [{:__aliases__, _, parts} | _]} ->
        List.starts_with?(parts, pattern)

      {:import, _, [{:__aliases__, _, parts} | _]} ->
        List.starts_with?(parts, pattern)

      _ ->
        false
    end)
  end

  defp infrastructure_file?(file) do
    String.contains?(file, "/infrastructure/") or
      String.contains?(file, "/adapter") or
      String.ends_with?(file, "/application.ex") or
      String.ends_with?(file, "/mailer.ex") or
      String.ends_with?(file, "/endpoint.ex")
  end
end
