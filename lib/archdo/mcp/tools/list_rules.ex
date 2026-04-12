defmodule Archdo.Mcp.Tools.ListRules do
  @moduledoc false

  alias Archdo.Runner

  def name, do: "archdo_list_rules"

  def description do
    "List every rule Archdo can apply, optionally filtered by category. " <>
      "Returns the rule id, category, and short description for each rule. " <>
      "Use this when you want to know what kinds of architectural issues Archdo checks for, " <>
      "or to discover the id of a rule you want to explain or run."
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "category" => %{
          "type" => "string",
          "description" =>
            "Optional category filter. One of: boundaries, public_api, ssot, coupling, otp, module_quality, testing, event_sourcing, state_machine, composition, nif."
        }
      },
      "additionalProperties" => false
    }
  end

  def call(args) when is_map(args) do
    rules = all_rules()

    filtered =
      case Map.get(args, "category") do
        nil -> rules
        "" -> rules
        category -> Enum.filter(rules, &match_category?(&1, category))
      end

    {:ok,
     %{
       count: length(filtered),
       rules: Enum.map(filtered, &rule_summary/1)
     }}
  end

  defp all_rules do
    (Runner.phase1_rules() ++ Runner.graph_rules())
    |> Enum.uniq()
    |> Enum.sort_by(&rule_sort_key/1)
  end

  defp rule_summary(mod) do
    %{
      id: mod.id(),
      category: category_for(mod.id()),
      description: mod.description(),
      module: module_name(mod)
    }
  end

  defp module_name(mod), do: mod |> to_string() |> String.replace_leading("Elixir.", "")

  defp rule_sort_key(mod) do
    id = mod.id()

    case String.split(id, ".", parts: 2) do
      [major, minor] ->
        {String.to_integer(strip_letters(major)), minor}

      [only] ->
        {String.to_integer(strip_letters(only)), ""}
    end
  rescue
    _ -> {999, mod.id()}
  end

  defp strip_letters(str), do: String.replace(str, ~r/[^0-9]/, "")

  defp category_for("1." <> _), do: "boundaries"
  defp category_for("2." <> _), do: "public_api"
  defp category_for("3." <> _), do: "ssot"
  defp category_for("4." <> _), do: "coupling"
  defp category_for("5." <> _), do: "otp"
  defp category_for("6." <> _), do: "module_quality"
  defp category_for("7." <> _), do: "testing"
  defp category_for("8." <> _), do: "event_sourcing"
  defp category_for("9." <> _), do: "state_machine"
  defp category_for("10." <> _), do: "composition"
  defp category_for("11." <> _), do: "nif"
  defp category_for(_), do: "other"

  defp match_category?(mod, category) do
    String.downcase(category) == category_for(mod.id())
  end
end
