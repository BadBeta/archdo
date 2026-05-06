defmodule Archdo.Rules.OTP.InlineEffectInBuildingBlock do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "5.74"

  @impl true
  def description,
    do: "Side-effecting call inside a module declared as a building block"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_inline_effects(file, ast)
    end
  end

  defp find_inline_effects(file, ast) do
    case building_block?(ast) do
      true -> collect_effects(file, ast)
      false -> []
    end
  end

  # `@moduledoc "Building block: ..."` — case-insensitive, matches both
  # "building block" and "building-block".
  defp building_block?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:moduledoc, _, [doc]}]} -> moduledoc_marks_building_block?(doc)
      _ -> false
    end)
  end

  defp moduledoc_marks_building_block?(doc) do
    case Unwrap.string(doc) do
      s when is_binary(s) ->
        lower = String.downcase(s)
        String.contains?(lower, "building block") or String.contains?(lower, "building-block")

      _ ->
        false
    end
  end

  defp collect_effects(file, ast) do
    ast
    |> AST.find_all(&effect_call?/1)
    |> Enum.map(fn node -> build_diagnostic(file, AST.line(call_meta(node)), describe(node)) end)
  end

  # Logger.<level>(...)
  defp effect_call?({{:., _, [{:__aliases__, _, [:Logger]}, level]}, _, _})
       when level in [
              :debug,
              :info,
              :warning,
              :warn,
              :error,
              :critical,
              :alert,
              :emergency,
              :notice
            ],
       do: true

  # Phoenix.PubSub.broadcast / broadcast! / local_broadcast / direct_broadcast
  defp effect_call?({{:., _, [{:__aliases__, _, [:Phoenix, :PubSub]}, op]}, _, _})
       when op in [:broadcast, :broadcast!, :local_broadcast, :direct_broadcast, :broadcast_from],
       do: true

  # MyApp.Repo.insert / update / delete / insert_all / ... (heuristic: any call to a Repo-named alias)
  defp effect_call?({{:., _, [{:__aliases__, _, parts}, op]}, _, _})
       when is_list(parts) and
              op in [
                :insert,
                :update,
                :delete,
                :insert_all,
                :update_all,
                :delete_all,
                :insert!,
                :update!,
                :delete!
              ] do
    Enum.any?(parts, &is_repo_alias?/1)
  end

  # :telemetry.execute / span / attach
  defp effect_call?({{:., _, [:telemetry, op]}, _, _})
       when op in [:execute, :span, :attach, :attach_many],
       do: true

  # :ets.insert / delete / update_counter / etc.
  defp effect_call?({{:., _, [:ets, op]}, _, _})
       when op in [
              :insert,
              :insert_new,
              :delete,
              :delete_object,
              :update_counter,
              :update_element,
              :give_away
            ],
       do: true

  # :persistent_term.put / erase
  defp effect_call?({{:., _, [:persistent_term, op]}, _, _})
       when op in [:put, :erase],
       do: true

  defp effect_call?(_), do: false

  defp is_repo_alias?(part) when is_atom(part) do
    str = Atom.to_string(part)
    str == "Repo" or String.ends_with?(str, "Repo")
  end

  defp is_repo_alias?(_), do: false

  defp call_meta({_, meta, _}), do: meta

  defp describe({{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _}), do: "Logger"

  defp describe({{:., _, [{:__aliases__, _, [:Phoenix, :PubSub]}, _]}, _, _}),
    do: "Phoenix.PubSub"

  defp describe({{:., _, [{:__aliases__, _, _}, op]}, _, _})
       when op in [
              :insert,
              :update,
              :delete,
              :insert_all,
              :update_all,
              :delete_all,
              :insert!,
              :update!,
              :delete!
            ],
       do: "Repo"

  defp describe({{:., _, [:telemetry, _]}, _, _}), do: "telemetry"
  defp describe({{:., _, [:ets, _]}, _, _}), do: "ets"
  defp describe({{:., _, [:persistent_term, _]}, _, _}), do: "persistent_term"
  defp describe(_), do: "side-effect"

  defp build_diagnostic(file, line, kind) do
    Diagnostic.info("5.74",
      title: "Inline side-effect in building-block module",
      message:
        "This module's `@moduledoc` declares it a building block, but the body " <>
          "calls #{kind} — a side effect. Building blocks must be pure.",
      why:
        "A building block (per the seven-axis checklist) must be side-effect " <>
          "free: same input → same output, no Logger / PubSub / Repo / " <>
          "telemetry / ETS / persistent_term writes. Side effects belong in " <>
          "the orchestrator that calls the building block, not inside it. " <>
          "Mixing pure logic with effects defeats the building-block " <>
          "guarantee — testing with property-based tests becomes impossible, " <>
          "callers can no longer trust the function's signature, and " <>
          "Archdo's Blackbox analyzer will demote it.",
      alternatives: [
        Fix.new(
          summary: "Extract the effect to the orchestrator",
          detail:
            "Have the building block return data; let the caller (an " <>
              "orchestrator module) emit the side effect.",
          example: """
          ```elixir
          # before — building block does I/O
          def discount(price, rate) do
            Logger.info("calculating discount")
            price * (1 - rate)
          end

          # after — building block stays pure
          def discount(price, rate), do: price * (1 - rate)

          # orchestrator (caller)
          def apply_discount(price, rate) do
            Logger.info("calculating discount")
            Pricing.discount(price, rate)
          end
          ```
          """,
          applies_when: "The effect is observability/audit, not part of the computation."
        ),
        Fix.new(
          summary: "Reclassify the module as an orchestrator",
          detail:
            "If the effect is genuinely intrinsic to the operation, this isn't " <>
              "a building block — update the `@moduledoc` to remove the " <>
              "claim, and rename the module if appropriate.",
          applies_when: "The module's purpose is orchestration, not pure computation."
        )
      ],
      file: file,
      line: line
    )
  end
end
