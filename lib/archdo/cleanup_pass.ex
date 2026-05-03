defmodule Archdo.CleanupPass do
  @moduledoc """
  Maps Archdo rule identifiers to cleanup-guide pass numbers (1..14).

  The cleanup guide
  (`comprehensive_elixir_codebase_cleanup_guide.md`) groups Elixir code
  defects into 16 ordered passes. Archdo's rules detect specific shapes
  of these defects; this module is the canonical mapping.

  Pass 0 (baseline/inventory) and pass 15 (final verification) are not
  detection concerns — they sit outside this mapping.

  ## Resolution order

  When asked for a rule's pass, callers should prefer
  `Archdo.Rule.cleanup_pass_of/1`, which:

    1. Returns `cleanup_pass/0` from the rule module if it implements
       the optional callback.
    2. Falls back to `Archdo.CleanupPass.pass_for/1` lookup.
    3. Returns `nil` for rules that don't address a cleanup-guide
       pass (Archdo-unique architectural rules — boundary leakage
       metrics, blackbox quadrant, etc.).
  """

  @type pass :: 1..14

  # §§ elixir-implementing: §1 #23 SSOT — the mapping is the single
  # source of truth for rule → pass. New rules SHOULD declare
  # `cleanup_pass/0` directly; this map is the back-compat layer for
  # pre-existing rules that haven't been touched.

  # Rules that already declare cleanup_pass/0 directly are intentionally
  # NOT in this map (the callback wins). The exception is :"3.2"
  # (scattered_config), kept here so the map alone tells the full
  # story when someone is reading the catalog.
  @rule_passes %{
    # ── Pass 2 — Boundary and DTO Integrity ─────────────────────────
    "1.12" => 2,
    "1.14" => 2,
    "1.21" => 2,
    "6.39" => 2,

    # ── Pass 3 — Atom Safety and Bounded Vocabulary ─────────────────
    "1.20" => 3,
    "5.24" => 3,
    "5.27" => 3,

    # ── Pass 4 — Configuration and Ambient Authority ────────────────
    "3.2" => 4,
    "1.32" => 4,
    "6.40" => 4,

    # ── Pass 5 — Secret Redaction and Error Sanitization ────────────
    "5.52" => 5,
    "5.53" => 5,
    "5.54" => 5,
    "6.56" => 5,

    # ── Pass 6 — Unsafe Deserialization and Runtime Eval ────────────
    "5.50" => 6,
    "5.51" => 6,

    # ── Pass 7 — OTP Lifecycle and Supervision Integrity ────────────
    "5.1" => 7,
    "5.2" => 7,
    "5.6" => 7,
    "5.7" => 7,
    "5.8" => 7,
    "5.10" => 7,
    "5.11" => 7,
    "5.16" => 7,
    "5.17" => 7,
    "5.21" => 7,
    "5.30" => 7,

    # ── Pass 8 — Mailbox / Backpressure / Queue Bounds ──────────────
    "5.4" => 8,
    "5.18" => 8,
    "5.20" => 8,
    "5.22" => 8,
    "5.31" => 8,
    "5.33" => 8,
    "6.13" => 8,

    # ── Pass 9 — GenServer Functional-Core Cleanup ──────────────────
    "5.3" => 9,
    "5.5" => 9,
    "5.9" => 9,
    "5.13" => 9,
    "5.19" => 9,
    "5.23" => 9,
    "5.26" => 9,

    # ── Pass 10 — Serialization, Protocol, Versioning ───────────────
    "1.22" => 10,
    "8.1" => 10,
    "8.2" => 10,
    "8.3" => 10,
    "8.5" => 10,
    "8.9" => 10,
    "6.41" => 10,

    # ── Pass 11 — Persistence and State Backend Cleanup ─────────────
    "1.4" => 11,
    "1.5" => 11,
    "1.6" => 11,
    "1.10" => 11,
    "1.16" => 11,
    "1.17" => 11,
    "1.18" => 11,
    "1.19" => 11,

    # ── Pass 12 — Package and Dependency Boundaries ─────────────────
    "1.1" => 12,
    "1.2" => 12,
    "1.3" => 12,
    "1.7" => 12,
    "1.8" => 12,
    "1.9" => 12,
    "1.11" => 12,
    "1.13" => 12,
    "1.15" => 12,

    # ── Pass 13 — Observability and Context Propagation ─────────────
    "5.55" => 13,
    "6.36" => 13,
    "6.37" => 13,
    "CE-19" => 13,

    # ── Pass 14 — Idiomatic / Performance / Maintainability ─────────
    "6.1" => 14,
    "6.2" => 14,
    "6.3" => 14,
    "6.4" => 14,
    "6.10" => 14,
    "6.18" => 14,
    "6.19" => 14,
    "6.21" => 14,
    "6.22" => 14,
    "6.49" => 14
  }

  @pass_labels %{
    1 => "Transformation Safety",
    2 => "Boundary and DTO Integrity",
    3 => "Atom Safety and Bounded Vocabulary",
    4 => "Configuration and Ambient Authority",
    5 => "Secret Redaction and Error Sanitization",
    6 => "Unsafe Deserialization and Runtime Eval",
    7 => "OTP Lifecycle and Supervision Integrity",
    8 => "Mailbox, Backpressure, and Queue Bounds",
    9 => "GenServer Functional-Core Cleanup",
    10 => "Serialization, Protocol, and Versioning",
    11 => "Persistence and State Backend Cleanup",
    12 => "Package and Dependency Boundaries",
    13 => "Observability and Context Propagation",
    14 => "Idiomatic, Performance, and Maintainability"
  }

  @doc "Returns the cleanup-guide pass number for the given rule id, or `nil`."
  @spec pass_for(String.t()) :: pass() | nil
  def pass_for(rule_id) when is_binary(rule_id), do: Map.get(@rule_passes, rule_id)

  @doc """
  Filters a list of rule modules to those tagged with the given pass.
  Resolution honors `cleanup_pass/0` callback first, mapping second.
  Returns `[]` for any non-1..14 pass value rather than raising.
  """
  @spec rules_for(integer(), [module()]) :: [module()]
  def rules_for(pass, rules) when is_integer(pass) and is_list(rules) do
    Enum.filter(rules, fn rule -> Archdo.Rule.cleanup_pass_of(rule) == pass end)
  end

  @doc "Returns the canonical 1..14 pass list."
  @spec all_passes() :: [pass()]
  def all_passes, do: Enum.to_list(1..14)

  @doc "Human-readable label for a pass number."
  @spec pass_label(pass()) :: String.t()
  def pass_label(pass) when pass in 1..14, do: Map.fetch!(@pass_labels, pass)
end
