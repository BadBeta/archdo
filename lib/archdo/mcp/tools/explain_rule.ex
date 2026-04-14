defmodule Archdo.Mcp.Tools.ExplainRule do
  @moduledoc false

  alias Archdo.Runner

  def name, do: "archdo_explain_rule"

  def description do
    "Look up a rule by id and return its full canonical explanation: title, severity, description, " <>
      "and a link to the architectural rules document. Use this when a diagnostic mentions a rule id " <>
      "you don't recognize, or when the user asks why a rule exists."
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{
          "type" => "string",
          "description" =>
            "The rule id, e.g. \"5.11\" or \"8.2\". Use archdo_list_rules to discover ids."
        }
      },
      "required" => ["id"],
      "additionalProperties" => false
    }
  end

  def call(%{"id" => id}) when is_binary(id) do
    case find_rule(id) do
      nil ->
        {:error, "no rule found with id #{inspect(id)}"}

      mod ->
        {:ok,
         %{
           id: mod.id(),
           module: module_name(mod),
           description: mod.description(),
           reference: "ARCHITECTURE_RULES.md##{mod.id()}",
           note:
             "For the full canonical explanation including examples and tolerances, read the matching section in ARCHITECTURE_RULES.md."
         }}
    end
  end

  def call(_), do: {:error, "missing required `id` argument"}

  defp find_rule(id) do
    all = Runner.phase1_rules() ++ Runner.graph_rules()
    Enum.find(all, fn mod -> mod.id() == id end)
  end

  defp module_name(mod), do: Archdo.AST.module_name(mod)
end
