defmodule Archdo.Rules.CE.WrapperOverFramework do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — first Change Economy rule (M16). Detects
  # behaviours whose single (or zero) non-test implementor wraps a
  # framework primitive that already provides Substitutability via a
  # documented test seam (Ecto.Repo + Sandbox, Phoenix.PubSub testing
  # helpers, Oban + Oban.Testing, OTP primitives + start_supervised).
  # The wrapper pays the layer cost for capabilities that already exist
  # — both Changeability and Substitutability suffer.
  #
  # Framework-seam set is derived from `Archdo.Volatility`'s
  # `:stable_with_test_seam` profile entries — same source-of-truth.

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "CE-15"

  @impl true
  def description,
    do: "Wrapper layer over framework-provided abstraction (with existing test seam)"

  @doc """
  Project-level analysis. Walks `file_asts`, builds the behaviour /
  implementor registry, and fires on each behaviour whose single
  non-test implementor's principal call target is a framework
  abstraction with its own test seam.
  """
  @spec analyze_project([{String.t(), Macro.t()}]) :: [Diagnostic.t()]
  def analyze_project(file_asts) do
    seam_targets = framework_seam_targets()
    behaviours = collect_behaviours(file_asts)
    implementors = collect_implementors(file_asts)

    for {behaviour_name, b_file, b_ast} <- behaviours,
        not extension_point?(b_ast),
        impls = Map.get(implementors, behaviour_name, []),
        non_test_impls = Enum.reject(impls, fn {_m, file, _ast} -> AST.test_file?(file) end),
        # v1 conservatism: only fire when there's exactly one production
        # impl AND it wraps a framework-seam target. The 0-impl path is
        # off because it false-positives heavily on Ecto.Type behaviours
        # and extension-point APIs (OpenTelemetry-style). Re-enable when
        # we have a stronger signal for the wrapper-without-impl case.
        length(non_test_impls) == 1,
        wrapped_target = wrapped_seam_target(non_test_impls, seam_targets),
        wrapped_target != nil,
        not policy_wrapped?(non_test_impls) do
      build_diagnostic(behaviour_name, b_file, wrapped_target, non_test_impls)
    end
  end

  defp extension_point?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:archdo_extension_point, _, _}]} -> true
      _ -> false
    end)
  end

  # --- discovery ---

  defp collect_behaviours(file_asts) do
    Enum.flat_map(file_asts, fn {file, ast} ->
      has_callback? =
        AST.contains?(ast, fn
          {:@, _, [{:callback, _, _}]} -> true
          _ -> false
        end)

      case has_callback? do
        true ->
          name = AST.extract_module_name(ast)
          [{name, file, ast}]

        false ->
          []
      end
    end)
  end

  defp collect_implementors(file_asts) do
    Enum.reduce(file_asts, %{}, fn {file, ast}, acc ->
      module = AST.extract_module_name(ast)

      ast
      |> behaviour_refs()
      |> Enum.reduce(acc, fn behaviour_name, acc2 ->
        Map.update(acc2, behaviour_name, [{module, file, ast}], &[{module, file, ast} | &1])
      end)
    end)
  end

  defp behaviour_refs(ast) do
    AST.find_all(ast, fn
      {:@, _, [{:behaviour, _, [{:__aliases__, _, _}]}]} -> true
      _ -> false
    end)
    |> Enum.flat_map(fn
      {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]} ->
        case Enum.all?(parts, &is_atom/1) do
          true -> [AST.join_alias_parts(parts)]
          false -> []
        end

      _ ->
        []
    end)
  end

  # --- principal call target ---

  defp wrapped_seam_target([], seam_targets) do
    # No implementor — treat as zero-impl wrapper. Fire with target
    # inferred as :any framework primitive when the behaviour name hints
    # at one. Conservative: only fire with a generic message.
    {:no_impl, MapSet.to_list(seam_targets) |> List.first() || nil}
  end

  defp wrapped_seam_target(impls, seam_targets) do
    impls
    |> Enum.flat_map(fn {_mod, _file, ast} -> external_calls(ast) end)
    |> Enum.frequencies_by(& &1)
    |> Enum.sort_by(fn {_mod, count} -> -count end)
    |> Enum.find_value(fn {mod, _count} ->
      case MapSet.member?(seam_targets, mod) do
        true -> {:wrapped, mod}
        false -> nil
      end
    end)
  end

  defp external_calls(ast) do
    own_module = AST.extract_module_name(ast)

    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, parts}, _fun]}, _, _} when is_list(parts) ->
        Enum.all?(parts, &is_atom/1)

      _ ->
        false
    end)
    |> Enum.flat_map(fn
      {{:., _, [{:__aliases__, _, parts}, _fun]}, _, _} ->
        target = AST.join_alias_parts(parts)

        case target == own_module or self_call?(own_module, target) do
          true -> []
          false -> [Module.concat(parts)]
        end

      _ ->
        []
    end)
  end

  defp self_call?(own, target) do
    String.starts_with?(target, own <> ".")
  end

  defp policy_wrapped?(impls) do
    Enum.any?(impls, fn {_mod, _file, ast} ->
      AST.contains?(ast, fn
        {:@, _, [{:archdo_policy_wrapper, _, _}]} -> true
        _ -> false
      end)
    end)
  end

  # --- framework seam set (sourced from Volatility profile) ---

  defp framework_seam_targets do
    # Hard-coded for now to mirror Volatility's :stable_with_test_seam
    # entries. When CE-15 needs project overrides, replace with a call
    # that reads the live Volatility profile via opts; keeping it static
    # for v1 because no rule yet hands a live profile to project rules.
    MapSet.new([Ecto.Repo, Phoenix.PubSub, Oban, Task, Task.Supervisor, GenServer, Agent])
  end

  # --- diagnostic ---

  defp build_diagnostic(behaviour_name, file, {kind, wrapped}, impls) do
    {message, why_extra} =
      case kind do
        :wrapped ->
          {"Behaviour #{behaviour_name} wraps framework abstraction #{inspect(wrapped)} " <>
             "(its single implementor delegates to it as the principal call target)",
           "The framework already provides a test seam for #{inspect(wrapped)} " <>
             "(Sandbox / testing helpers / start_supervised). The wrapper adds a layer " <>
             "for capabilities that already exist."}

        :no_impl ->
          {"Behaviour #{behaviour_name} has no production implementor",
           "An abstraction with no concrete production implementor is overhead — " <>
             "either delete the behaviour, or document the planned production impl."}
      end

    impl_summary =
      case impls do
        [] ->
          "no production implementor"

        [{m, _, _}] ->
          "single implementor: #{m}"

        many ->
          "#{length(many)} implementors: #{Enum.map_join(many, ", ", fn {m, _, _} -> m end)}"
      end

    Diagnostic.warning("CE-15",
      title: "Wrapper layer over framework-provided abstraction",
      message: message,
      why:
        "Double abstraction. " <>
          why_extra <>
          " The wrapper typically also fails to expose all the framework's features " <>
          "cleanly (transactions, multi, telemetry, supervisor integration), forcing " <>
          "leaky-abstraction escape hatches later.",
      alternatives: [
        Fix.new(
          summary: "Delete the behaviour and call the framework primitive directly",
          detail:
            "Use the framework's own test seam (Ecto.Sandbox, Oban.Testing, " <>
              "Phoenix.PubSub testing helpers, start_supervised) in tests; have " <>
              "callers invoke the primitive directly.",
          applies_when: "The wrapper is a thin pass-through with no policy enforcement."
        ),
        Fix.new(
          summary: "Mark as a policy wrapper if it adds enforcement the framework lacks",
          detail:
            "If the wrapper enforces tenant scoping, read-replica routing, audit " <>
              "logging, or another policy the framework doesn't provide, mark with " <>
              "`@archdo_policy_wrapper \"<one-line reason>\"` to suppress this " <>
              "finding.",
          applies_when: "The wrapper genuinely adds policy enforcement on every call."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-15"],
      context: %{
        behaviour: behaviour_name,
        wrapped: inspect(wrapped),
        impl_summary: impl_summary
      },
      file: file,
      line: 1
    )
  end
end
