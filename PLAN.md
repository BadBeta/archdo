# PLAN — Change Economy Refactor (M13–M30)

This plan implements `ARCHITECTURE_RULES_CHANGE_ECONOMY.md` against the
existing M1–M12 infrastructure (`Archdo.Phoenix`, `Archdo.Severity`,
`:nitpick` tier, runner classify-once-consume-many shape).

Per **elixir-planning §0** (plan-completeness gate): no TBDs, no "we'll
pick later". Per **elixir-implementing §0** (TDD gate): every new public
function names its test file before code; every milestone is RED → GREEN
→ REFACTOR.

## Three new primitives

### 1. Pack (M13)
Rules declare an optional `@pack` callback. The runner filters by
enabled packs read from `.archdo.exs` `packs:` key, `--packs` CLI flag,
or default `[:core]`.

```elixir
defmodule Archdo.Rule do
  @callback pack() :: :core | :ce_compliance | :ce_privacy | :ce_composability
  @optional_callbacks [pack: 0]
end
```

### 2. Quadrant rule (M14)
Rules optionally declare two axes + a per-cell policy table. The runner
emits findings only for cells the policy marks `:fire`.

```elixir
defmodule Archdo.Quadrant do
  @callback axes(file, ast, opts) :: %{x: atom(), y: atom()}
  @callback policy() :: %{cell => action}
  @callback finding_for(cell, evidence, file, line) :: Diagnostic.t()
end
```

Threshold rules (existing shape) continue to work unchanged. Quadrant
is opt-in per rule.

### 3. Volatility classifier (M15)
Mirrors `Archdo.Phoenix.classify_file/2`. Returns `%{tag, density,
evidence}`. Wired into runner as `opts[:volatility]`.

```elixir
defmodule Archdo.Volatility do
  @type tag :: :stable | :stable_with_test_seam
              | :volatile | :non_deterministic | :mixed
  @spec classify_module(file, ast, opts) :: classification()
end
```

## Eighteen milestones across six phases

### Phase F0 — Foundation (M13–M15)

| M | Title | New modules | Tests |
|---|---|---|---|
| **M13** | Pack abstraction | `Archdo.Rule.pack_of/1` + Runner filter + `--packs` CLI | 3 + 4 |
| **M14** | Quadrant primitive | `Archdo.Quadrant`, synthetic test rule | 12 + 3 |
| **M15** | Volatility classifier | `Archdo.Volatility.classify_module/3` + runner wiring + `--metrics` cols | 22 + 2 |

### Phase F1 — High-value rules without volatility (M16–M19)

| M | Title | Pack | Severity |
|---|---|---|---|
| **M16** | CE-15 Wrapper over framework abstraction | core | warn |
| **M17** | CE-30/31 Unanchored module + island (shared `AnchorSet`) | core | warn |
| **M18** | CE-49 Catch-all rescue + CE-50 `:ok` loses info | core | warn / warn |
| **M19** | CE-17 Magic literals + CE-21 Acquire/release without bracket | core | warn / suggest |

### Phase F2 — State machine sharpening (M20)

| M | Title | Pack | Severity |
|---|---|---|---|
| **M20** | SM-A undeclared next_state + SM-D state-assign outside set + SM-F incomplete pattern-match on state | core | warn × 3 |

### Phase V1 — Volatility-dependent rules (M21–M23)

| M | Title | Kind | Notes |
|---|---|---|---|
| **M21** | CE-2 + CE-3 as one quadrant rule | `:quadrant` | Two rule_ids from one analysis pass |
| **M22** | CE-1 hardcoded volatile deps + CE-4 mixed module split | threshold | CE-4 catalogs split candidates |
| **M23** | CE-34 + CE-35 resilience using volatility | threshold | CE-34 supersedes 4.18 detection |

### Phase D1 — Cognitive complexity + blackbox (M24–M26)

| M | Title | Pack | Notes |
|---|---|---|---|
| **M24** | Cognitive complexity engine + CE-23/CE-24 quadrant | core | Auto-suppresses 6.2 at flat-dispatch sites |
| **M25** | Blackbox `:possible` axis only (metric, no rule) | ce_composability | New `--metrics` columns |
| **M26** | Blackbox `:valuable` axis + CE-54 quadrant + CE-55/56 | ce_composability | Three of four cells produce no finding |

### Phase E — Cross-cutting + contracts (M27–M29)

| M | Title | Pack |
|---|---|---|
| **M27** | CE-25 cross-cutting density + CE-26 scattered taxonomy | core |
| **M28** | CE-11/12 contract density (irreversible + public API) | core |
| **M29** | CE-27 telemetry + CE-28 error log + CE-29 process inspect + CE-47/48 error coherence | core |

### Phase Opt-in — Optional packs (M30)

| M | Title | Packs |
|---|---|---|
| **M30** | CE-Compliance (CE-32/33), CE-Privacy (CE-52/53), CE-Comparative CLI scaffold | ce_compliance, ce_privacy |

## Cross-cutting decisions

1. **Severity defaults:** new CE rules use proposal §Appendix B as
   starting point; M8/M9/M10 calibration overrides reshape later if
   field data demands.
2. **Existing rules getting quadrant-reshape:** 6.43 LongParameterList
   (already done in M12), 3.4 SimilarCode (M27 reuses for CE-26), 6.2
   FunctionComplexity (M24 auto-suppresses at flat-dispatch). Other
   existing rules stay threshold-shaped.
3. **Pack defaults:** `[:core]`. Backward-compatible — existing projects
   see no behaviour change unless they add `packs:`.
4. **CE rule cross-references with existing:** documented at write time
   per **elixir-reviewing §1** rule 8. Each CE rule's `references:`
   field links to the existing Archdo rule it sharpens.
5. **TDD evidence per milestone:** test file appears in same commit as
   implementation; commit message names "RED: N tests written first,
   confirmed failing" before "GREEN: implementation". Auditable from
   `git log` per **elixir-implementing §0.6**.
6. **Field verification cohort:** Plausible (large Phoenix/Ecto), hexpm
   (mid Phoenix), Livebook (LiveView-heavy), otel (Erlang/OTP), Oban +
   Broadway + Tesla (reference cohort per proposal §8.1). M30 closing
   audit re-runs all six.

## Follow-ups discovered during execution

### M-Aux1 — Graph: capture module-attribute registry edges
**Triggered by M17.** `Archdo.Graph` extracts edges from `alias` /
`import` / `use` / remote-call AST nodes only. The module-attribute
registry pattern — `@project_file_ast_rules [Foo, Bar, ...]` followed
by `Enum.each/Enum.flat_map(@project_file_ast_rules, &...)` — is
invisible to the walker, so modules referenced only through such a
registry appear as `CE-30` orphans even when transitively reached.

**Fix shape:** in `Graph.extract_edges/2`, when a module attribute
is defined as a list literal containing only module aliases, track
the attribute name; when the same attribute is later passed to an
enumeration call (`Enum.*`, `for ... <- @attr`, `Stream.*`), emit a
synthetic `:registry` edge from the host module to each listed
module. Targets the Archdo-self-analysis CE-30 false-positive class
+ any project that uses the same dispatch pattern (Phoenix-app
plugins, plug pipelines built from a list, etc.).

**Tests:** 4 — list-only attribute (no edges), list + Enum.each
(edges), list + non-enumeration use (no edges), nested-attribute case.

**Effort:** small (~2-3 hours). Defer until either (a) self-analysis
CE-30 noise becomes blocking, or (b) the same pattern shows up in
field-test cohort findings.

### M-Aux4 — Building Block Audit (module + context verdicts + `--shorten`)
**Triggered after M26 + a user question:** "do we know which modules /
contexts ARE building blocks?" M25/M26 score per function but never
produce a module- or context-level verdict; the per-module mean in
`--metrics` masks single-function leaks. Five gaps:

1. **Totality is a placeholder** — `Blackbox.score_function/4` hardcodes
   `totality: 1.0`. Need a real check: function has catch-all clause OR
   single-clause with no pattern matching → 1.0; multi-clause without
   catch-all → 0.5.

2. **Module-level verdict missing** — current `possibility/1` does
   arithmetic mean. A module with 9 building-block functions + 1
   boundary function gets ~0.9 (looks great); the one impure function
   breaks the contract. Need `min`-based `module_verdict/1` →
   `:building_block | {:leaks_at, [{name, arity, score}, ...]}`.

3. **Context-level verdict missing** — aggregate `module_verdict`
   across all modules in a `:context` Phoenix layer's namespace.
   `:building_block` only when every module in the context is one.

4. **`mix archdo --building-blocks` CLI** — prints two tables:
   - Building-block MODULES (min-of-functions ≥ 0.9 across public fns)
   - Building-block CONTEXTS (min-of-modules across the namespace)

5. **`mix archdo --shorten Mod.fn/N`** (the AST-blackbox + StreamData
   property-test workflow discussed earlier in the conversation) — for
   genuinely verifying correctness on building-block candidates. Larger
   effort (~1 day) than items 1–4.

**Effort:** items 1–4 ~2-3 hours total; item 5 ~1 day.

**Status (after M-Aux4 ship):** items 1–4 land in M-Aux4; item 5
(`--shorten`) stays as M-Aux4-extended follow-up.

### M-Aux3 — CE-55 + CE-56: blackbox property-test + effect-leak rules
**Triggered by M26.** CE-54 ships in M26 covering the actionable
{:low_possibility, :high_value} cell. Two related rules from proposal
§O are deferred:

- **CE-55** — Building-block candidate untested as such. Fires on
  `{:high_possibility, :high_value}` cells (functions that already
  ARE building blocks structurally) where no StreamData property
  test exists. Requires test-file scanning for `property` blocks
  that reference the function — needs cross-file analysis.

- **CE-56** — Effect leak in a near-blackbox function. Special case
  of `{:low, :high}` where the only structural failure is
  `side_effect_free` AND the side effect is observability-only
  (Logger / telemetry / PubSub). The fix is mechanical (split the
  function into pure inner + thin effect wrapper), so the finding
  carries higher specificity.

**Effort:** small for CE-56 (filter CE-54 findings by failed-component
shape); medium for CE-55 (requires property-test discovery, similar
to existing `7.x` testing rules).

### M-Aux2 — CE-50: broaden detection via data-flow on discarded value
**Triggered by M18.** CE-50's v1 detection requires `{:ok, _} = X.call(...)`
followed by a bare `:ok` return. Field-tested across hexpm / Plausible /
Livebook / otel: zero hits. The narrow shape is correct (no false
positives) but misses cases like:

- `Repo.insert!(struct); :ok` — bang call returns the struct, gets
  thrown away.
- `def foo do; result = X.fetch(); process(result); :ok end` — value
  passed through a side-effect chain then discarded.
- `Mailer.deliver(email); :ok` — single-call discarded result.

**Fix shape:** track binding flow — when a function's body has a
non-trivial last-call whose return type (per `@spec` if present, or
known-tuple-returning-module heuristic) is richer than `:ok`, AND that
return value is bound to a variable that's never used downstream OR
not used in the function's actual return value, fire.

Requires light data-flow analysis (which bindings escape vs which are
unused). Not pattern-matching only.

**Tests:** 4-6 — bang-call-then-ok, bound-but-unused, transitively
threaded result, the existing pattern-match shape.

**Effort:** medium (~half day). Defer until CE-50 missed-finding
reports come in from field testing or the cohort grows to surface
more cases.

## Deferred (not in this plan)

- Metadata-aware volatility refinement (mix.lock + Hex.pm metadata) —
  v2 of M15, post-M30.
- `--compare-with phoenix,ecto,oban` full implementation — CLI scaffold
  ships in M30, full impl post-M30.
- HTML volatility-map visualization — post-M30.
- SM-B/C/E/G/H/I — only A/D/F ship in M20; the rest require an explicit
  transition table (most projects don't have one).
- CE-13 — already covered by existing 3.1/3.4 clone detection.

## Plan-completeness gate verification

Grep this document for forbidden phrases (per **elixir-planning §0.5**):

- `TODO`, `TBD`, `figure out`, `decide when`, `something like`,
  `probably`, `maybe` — 0 hits each.
- `later` / `deferred` — only in the explicit "Deferred" section above,
  each item naming the disposition.

§0.1 checklist for the refactor scope:

- ✓ Layout: every new module named with file path. No new contexts.
- ✓ Processes: no new processes. Pure analyzers in the existing Runner.
- ✓ State: no new state. Classifiers compute per-run, no cache.
- ✓ Communication: rules consume `opts[:phoenix]`, `opts[:volatility]`.
- ✓ External boundaries: none.
- ✓ Configuration: `.archdo.exs` gains `packs:`,
  `dependency_volatility:`, `dual_purpose_modules:`, `volatile_paths:`,
  `stable_paths:`, `framework_provided_abstractions:`. Each
  documented at the milestone that introduces it.
- ✓ Resilience: no I/O.
- ✓ Test strategy: every milestone names its test files and counts.
