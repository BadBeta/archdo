defmodule Archdo.Rules.Module.MainSequenceDistance do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix}

  @warn_distance 0.6
  @error_distance 0.85
  # Minimum total coupling — modules with nearly zero graph connections aren't interesting
  @min_total_coupling 5

  @impl true
  def id, do: "6.8"

  @impl true
  def description,
    do: "Distance from main sequence — concrete/stable or abstract/unstable modules"

  @doc """
  Project-level: takes the metrics output from Archdo.Metrics.compute/2
  and flags modules far from the main sequence.

  Interpretation:
    * distance ≈ 0    — healthy (on the main sequence)
    * A=0, I=0, D=1   — Zone of Pain: concrete and stable. Rigid.
                         A module everyone depends on but has no extension points.
    * A=1, I=1, D=1   — Zone of Uselessness: abstract and unstable. No one uses it.
                         A behaviour nobody implements, or a protocol nobody derives.
  """
  def analyze_project(metrics, file_map) do
    for m <- metrics,
        m.distance >= @warn_distance and m.ca + m.ce >= @min_total_coupling,
        not stable_by_design?(m) do
      {severity, zone} = classify(m)
      file = Map.get(file_map, m.module, "unknown")
      build_distance_diag(m, zone, severity, file)
    end
  end

  # Modules that are stable + concrete by design — not a smell.
  #
  # The Martin metric pathologises any module with A=0 (no behaviours
  # defined), but for many shapes this is the correct end state:
  #
  #   - Framework conventions: Repo, Web, Config — depended on by
  #     design.
  #   - Per-domain leaf data: schema-like Reading / Event modules with
  #     no callees.
  #   - Stdlib-style utility modules: pure functions only, no
  #     behaviours, used widely. These cannot reach the main sequence
  #     by introducing abstractions because the abstraction has nothing
  #     to dispatch over — they ARE the leaf primitives that other
  #     code uses. Detection: A=0 AND Ce ≤ 2 (very low fan-out).
  #   - Naming convention helpers: `*.Helpers`, `*.Util`, `*.Utils`,
  #     `*.AST`, `*.Naming` — community-standard "this is a utility
  #     module" suffixes.
  defp stable_by_design?(m) do
    mod_str = m.module

    String.ends_with?(mod_str, ".Repo") or
      String.ends_with?(mod_str, "Web") or
      String.ends_with?(mod_str, ".Config") or String.ends_with?(mod_str, ".Configuration") or
      utility_suffix?(mod_str) or
      ((String.ends_with?(mod_str, ".Reading") or String.ends_with?(mod_str, ".Event")) and
         m.abstractness == 0.0 and m.ce <= 1) or
      leaf_utility?(m)
  end

  defp utility_suffix?(mod_str) do
    String.ends_with?(mod_str, ".Helpers") or
      String.ends_with?(mod_str, ".Helper") or
      String.ends_with?(mod_str, ".Util") or
      String.ends_with?(mod_str, ".Utils") or
      String.ends_with?(mod_str, ".AST") or
      String.ends_with?(mod_str, ".Naming")
  end

  # A leaf utility module: no abstractness AND very low fan-out.
  # Such a module can't reach the main sequence by introducing
  # abstractions (it doesn't HAVE behaviour callees to abstract).
  # Stdlib-style helpers (Enum, Map, String) all match this shape.
  defp leaf_utility?(m) do
    m.abstractness == 0.0 and m.ce <= 2
  end

  defp build_distance_diag(m, zone, severity, file) do
    builder = Diagnostic.builder_for(severity)

    builder.("6.8",
      title: "Far from main sequence — #{zone}",
      message:
        "#{m.module} — Ca=#{m.ca} Ce=#{m.ce} I=#{format_pct(m.instability)} A=#{format_pct(m.abstractness)} D=#{format_pct(m.distance)}",
      why:
        "Martin's main sequence relates instability (I) and abstractness (A): healthy modules sit on the " <>
          "line A + I = 1. Modules far from this line are either rigid (concrete and depended-on, so changes " <>
          "ripple) or useless (abstract and not depended-on, so the abstraction is unused). Distance D is " <>
          "the perpendicular distance from the line and tells you how unbalanced the module is.",
      alternatives: zone_fixes(zone),
      references: ["ARCHITECTURE_RULES.md#6.8"],
      context: %{
        module: m.module,
        ca: m.ca,
        ce: m.ce,
        instability: m.instability,
        abstractness: m.abstractness,
        distance: m.distance,
        zone: zone
      },
      file: file,
      line: 1
    )
  end

  defp zone_fixes("Zone of Pain" <> _) do
    [
      Fix.new(
        summary: "Add an extension point (behaviour or protocol)",
        detail:
          "The module is concrete and many things depend on it, so changes ripple. Define a behaviour or " <>
            "protocol so consumers can target an interface instead of the concrete module. The new abstraction " <>
            "moves the module toward the main sequence.",
        applies_when: "The module is depended on by many consumers."
      ),
      Fix.new(
        summary: "Split the module into smaller pieces",
        detail:
          "If the module is large and rigid because it bundles too much, splitting reduces fan-in per piece " <>
            "and changes affect fewer consumers per change.",
        applies_when: "The module has multiple responsibilities."
      )
    ]
  end

  defp zone_fixes("Zone of Uselessness" <> _) do
    [
      Fix.new(
        summary: "Delete the abstraction",
        detail:
          "An abstract module with no dependents is speculative generality. Delete the behaviour or protocol " <>
            "and inline whatever uses it.",
        applies_when: "There's no concrete plan for consumers."
      ),
      Fix.new(
        summary: "Find or build a real consumer",
        detail:
          "If the abstraction was added in anticipation of consumers, build one (or wait until you actually " <>
            "have one) instead of carrying the dead code.",
        applies_when: "Consumers are imminent and documented."
      )
    ]
  end

  defp zone_fixes(_) do
    [
      Fix.new(
        summary: "Move toward the main sequence",
        detail:
          "Either make the module more stable (find more consumers) or more abstract (introduce extension " <>
            "points). The exact direction depends on which side of the main sequence the module is on.",
        applies_when: "Use the I/A/D values to decide which direction."
      )
    ]
  end

  defp classify(%{distance: d, abstractness: a, instability: i}) do
    severity = if d >= @error_distance, do: :warning, else: :info

    zone =
      cond do
        a < 0.3 and i < 0.3 -> "Zone of Pain (concrete + stable)"
        a > 0.7 and i > 0.7 -> "Zone of Uselessness (abstract + unstable)"
        true -> "far from main sequence"
      end

    {severity, zone}
  end

  defp format_pct(value) do
    :erlang.float_to_binary(value, decimals: 2)
  end
end
