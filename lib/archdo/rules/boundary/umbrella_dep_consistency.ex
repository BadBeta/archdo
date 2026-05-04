defmodule Archdo.Rules.Boundary.UmbrellaDepConsistency do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.30"

  @impl true
  def description, do: "Umbrella child apps with inconsistent dependency options"

  @impl true
  def analyze(file, ast, _opts) do
    # This rule only fires on umbrella root mix.exs or child mix.exs files
    # For simplicity, check each mix.exs for in_umbrella deps missing `only:`
    case AST.mix_exs?(file) do
      true -> check_umbrella_deps(file, ast)
      false -> []
    end
  end

  defp check_umbrella_deps(file, ast) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        # 3-element dep tuple with in_umbrella: true
        {:{}, meta,
         [
           {:__block__, _, [dep_name]},
           _version_or_opts,
           opts
         ]} = node,
        acc
        when is_atom(dep_name) and is_list(opts) ->
          case in_umbrella_without_override?(opts) do
            true ->
              {node, [build_diagnostic(file, AST.line(meta), dep_name, :missing_override) | acc]}

            false ->
              {node, acc}
          end

        # 2-element tuple where second element is keyword list with in_umbrella
        {:__block__, meta,
         [
           {{:__block__, _, [dep_name]}, opts}
         ]} = node,
        acc
        when is_atom(dep_name) and is_list(opts) ->
          case in_umbrella_without_override?(opts) do
            true ->
              {node, [build_diagnostic(file, AST.line(meta), dep_name, :missing_override) | acc]}

            false ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(diagnostics)
  end

  # Check if dep has in_umbrella: true but is missing `only:` when it's
  # a dep that should be restricted (e.g., a test-only sibling)
  # Actually — for umbrella deps, the main issue is different:
  # Check if an `in_umbrella: true` dep also has `runtime: false` without `only:`,
  # which means it's compiled but never started — potentially a misconfiguration.
  #
  # The more common issue: umbrella child has a dep like {:credo, ...} without
  # `only:` — this is already caught by rule 4.29. So this rule focuses on
  # in_umbrella deps that override env inconsistently.
  defp in_umbrella_without_override?(opts) do
    has_in_umbrella?(opts) and has_runtime_false?(opts) and not AST.dep_only_option?(opts)
  end

  defp has_in_umbrella?(opts) do
    Enum.any?(opts, fn
      {{:__block__, _, [:in_umbrella]}, {:__block__, _, [true]}} -> true
      {:in_umbrella, true} -> true
      _ -> false
    end)
  end

  defp has_runtime_false?(opts) do
    Enum.any?(opts, fn
      {{:__block__, _, [:runtime]}, {:__block__, _, [false]}} -> true
      {:runtime, false} -> true
      _ -> false
    end)
  end

  defp build_diagnostic(file, line, dep_name, :missing_override) do
    Diagnostic.info("4.30",
      title: "Umbrella dep with runtime: false but no only:",
      message:
        ":#{dep_name} has `in_umbrella: true, runtime: false` but no `only:` restriction — " <>
          "verify this is intentional",
      why:
        "In umbrella projects, `runtime: false` means the dependency is compiled but " <>
          "its application is not started. Without `only:`, it's compiled in all environments. " <>
          "If this is a test-only sibling, add `only: :test`. If it's a compile-time " <>
          "dependency (types, macros), `runtime: false` alone is correct.",
      alternatives: [
        Fix.new(
          summary: "Add `only:` if this is environment-specific",
          detail: "If :#{dep_name} is only needed in dev/test, add `only: [:dev, :test]`.",
          applies_when: "The sibling app is only used during development or testing."
        ),
        Fix.new(
          summary: "Keep as-is if compile-time only",
          detail:
            "If :#{dep_name} provides types, macros, or behaviours used at compile time, " <>
              "`runtime: false` without `only:` is correct.",
          applies_when: "The dependency is needed at compile time in all environments."
        )
      ],
      file: file,
      line: line
    )
  end
end
