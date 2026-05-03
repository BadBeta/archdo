defmodule Archdo.Rules.Module.AdaptersWithoutBehaviour do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.16"

  @impl true
  def description, do: "Multiple *Adapter modules should share a behaviour contract"

  @doc """
  Project-level: find modules named `*Adapter` and group them by parent namespace.
  Flag groups where 2+ siblings exist but none implement a common @behaviour.
  """
  def analyze_project(file_asts) do
    # Collect adapter modules with their behaviour usage
    adapters =
      Enum.flat_map(file_asts, fn {file, ast} ->
        name = AST.extract_module_name(ast)

        if adapter_module?(name) do
          [{name, file, AST.implements_behaviour?(ast)}]
        else
          []
        end
      end)

    # Group by parent namespace
    groups =
      adapters
      |> Enum.group_by(fn {name, _, _} -> parent_namespace(name) end)
      |> Enum.filter(fn {_, members} -> length(members) >= 2 end)

    Enum.flat_map(groups, &diag_for_adapter_group/1)
  end

  defp diag_for_adapter_group({parent, members}) do
    without_behaviour = Enum.reject(members, fn {_, _, has_bhv?} -> has_bhv? end)
    diag_if_all_unbound(length(without_behaviour) == length(members), parent, members)
  end

  # §§ elixir-implementing: §2.1 — boolean → multi-clause head
  defp diag_if_all_unbound(false, _parent, _members), do: []

  defp diag_if_all_unbound(true, parent, members) do
    names = Enum.map_join(members, ", ", fn {n, _, _} -> n end)
    {_, first_file, _} = hd(members)
    [build_adapter_diag(parent, members, names, first_file)]
  end

  defp build_adapter_diag(parent, members, names, first_file) do
    Diagnostic.info("4.16",
      title: "Adapter siblings without shared behaviour",
      message: "#{length(members)} adapter modules under #{parent} share no @behaviour: #{names}",
      why:
        "When two or more `*Adapter` modules live side-by-side without a shared behaviour, the " <>
          "implicit contract between them only exists in your head. Adding a method to one and forgetting " <>
          "to add it to the other compiles fine but breaks at runtime, and Mox can't generate a verifying " <>
          "mock for an undocumented contract.",
      alternatives: [
        Fix.new(
          summary:
            "Define `#{parent}.Adapter` with `@callback`s and have each adapter implement it",
          detail:
            "Extract the common operations into a behaviour module. Add `@behaviour #{parent}.Adapter` " <>
              "to each existing adapter and `@impl true` on the callback functions. The compiler now " <>
              "checks that every adapter implements every callback.",
          applies_when: "The adapters are interchangeable variants of the same contract."
        ),
        Fix.new(
          summary: "Promote one adapter as canonical and inline the others",
          detail:
            "If only one of the adapters is actively used and the others are vestigial, delete them and " <>
              "skip the behaviour ceremony entirely.",
          applies_when: "Most adapters aren't actually used."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.16"],
      context: %{namespace: parent, adapters: Enum.map(members, fn {n, _, _} -> n end)},
      file: first_file,
      line: 1
    )
  end

  defp adapter_module?(name) when is_binary(name) do
    last =
      name
      |> String.split(".")
      |> List.last("")

    String.ends_with?(last, "Adapter") or String.ends_with?(last, "Client")
  end

  defp parent_namespace(name) do
    parts = String.split(name, ".")

    case parts do
      [] ->
        "(root)"

      [_] ->
        "(root)"

      _ ->
        parts
        |> Enum.drop(-1)
        |> Enum.join(".")
    end
  end
end
