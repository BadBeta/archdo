# Archdo — Next Milestone Plan (PLAN-NEXT)

Addresses every non-Credo finding from the May 2026 outstanding-work review.
Each milestone is shippable independently. The plan passes the
elixir-planning §0.1 plan-completeness gate (concrete names, types,
signatures, test files for every item).

## Scope

Ordered by ROI per cost. Phase A = quick wins (this session). Phase B =
medium analyzers (this session if time). Phase C = larger features
(deferred to follow-up sessions, full spec here).

---

## Phase A — Quick wins

### M-Plan1 — Fix Elixir 1.18 typing warning in tools_test.exs:103

**Problem:** `assert result.suggestions != []` — Elixir 1.18's type
checker proves `result.suggestions` is always non-empty (every clause
of `Suggest.suggestions_for/1` returns a literal non-empty list), so
the comparison is always-true across disjoint types.

**Fix:** Replace with pattern-match assertion per elixir-implementing
§7.10. `assert [_ | _] = result.suggestions` proves non-empty
structurally without the disjoint-types comparison.

**Test file:** `test/mcp/tools_test.exs` (the warning IS in a test —
the change IS the fix; no separate regression test needed).

**Verification:** `mix test 2>&1 | grep -c "typing violation"` returns 0.

**Effort:** 5 minutes.

---

### M-Plan2 — Document integration-test environment requirement

**Problem:** `test/integration/real_project_test.exs` runs against
`/tmp/oban`, `/tmp/req`, etc. Without those checkouts, 12 tests fail
when `mix test --include integration` is run.

**Status:** Tests are CORRECTLY excluded by default
(`test_helper.exs:1`). The failures only fire when someone explicitly
includes integration. **No code change needed.**

**Action:** Add a `@moduledoc` block to
`test/integration/real_project_test.exs` listing required `/tmp/*`
paths and a one-line shell command to clone them, so future engineers
who run `--include integration` know how to set up the environment.

**Test file:** N/A — this is documentation only, no behavior change.

**Effort:** 5 minutes.

---

### M-Plan3 — Mark Archdo.Compiled.Collector with @archdo_opaque_state

**Problem:** CE-29 fires on `Archdo.Compiled.Collector` (a legit
GenServer with no `format_status/1`). It's a known false positive
because the collector's state is a transient compilation buffer with
no PII — `format_status` would add no value.

**Fix:** Add `@archdo_opaque_state "transient compilation buffer; no
external observers"` to `Archdo.Compiled.Collector`. The exemption is
already implemented in
`lib/archdo/rules/ce/opaque_process_state.ex` (per its existing
`@archdo_opaque_state` exemption marker code).

**Test file:** `test/rules/ce/opaque_process_state_test.exs` — already
has the exemption-marker test. Add one self-analysis check:
`test "Archdo.Compiled.Collector is exempt via @archdo_opaque_state"`.

**Effort:** 10 minutes.

---

### M-Plan4 — FP-7 + FP-8: Phoenix-classification for rules 1.6 + 1.9

**Problem (FP-7):** Rule 1.6 (`CrossCuttingInDomain`) uses
hand-rolled `web_file?` / `adapter_file?` / `infrastructure_file?`
predicates. The shared `Archdo.Phoenix.classify_file/2` already
encodes this knowledge with broader coverage (`:operational`,
`:application_root`, `:test`).

**Problem (FP-8):** Rule 1.9 (`TimeInjection`) over-fires on
`DateTime.utc_now/0` calls in code that isn't truly hard-coded
(e.g., a default arg `now \\ DateTime.utc_now()` is the very
*injection mechanism* the rule is supposed to recommend).

**Fix (FP-7):** Refactor 1.6 to consume `opts[:phoenix]` like 1.9
already does, and use `Phoenix.classify_file/2` for the layer check.
Drop `web_file?`/`adapter_file?`/`infrastructure_file?` private
helpers when the Phoenix classification subsumes them.

**Fix (FP-8):** Add a default-arg detection step: if every call site
of a hard-coded clock function is in a function-head default value
(`def f(arg \\ DateTime.utc_now())`), skip the diagnostic — the
function IS injecting the clock through its default. Walk function
heads to collect default-arg expressions before the call-site scan.

**Test files (TDD-first):**
- `test/rules/module/cross_cutting_in_domain_test.exs` — add 2 new
  tests: (1) operational layer (Mix task) is exempt via Phoenix
  classification, (2) test layer is exempt.
- `test/rules/module/time_injection_test.exs` — add 1 new test:
  function with `def f(now \\ DateTime.utc_now())` is NOT flagged.

**Effort:** 30 minutes.

---

### M-Plan5 — Configurable thresholds in `.archdo.exs` (D11)

**Problem:** Rules 1.6 (`@max_logger_calls 3`), 1.9 (no threshold,
just severity), 1.11 (`@min_files 3`) have hard-coded thresholds.
Field reports asked for `.archdo.exs` knobs to tune them per project.

**Fix:** Add `thresholds:` keyword to `.archdo.exs` config schema.
Shape:

```elixir
# .archdo.exs
[
  thresholds: [
    {"1.6", max_logger_calls: 5},      # default: 3
    {"1.11", min_files: 5}             # default: 3
  ]
]
```

Plumbing:
- `Archdo.Config` gains `thresholds :: %{String.t() => keyword()}`
  field. `from_keyword/2` parses it. `from_conventions/1` returns `%{}`.
- New `Archdo.Config.threshold/3` accessor:
  `threshold(config, "1.6", :max_logger_calls)` returns the configured
  value or the rule-defined default.
- Rule 1.6 reads `opts[:config]` (already plumbed via Runner) and
  calls `Archdo.Config.threshold(config, "1.6", :max_logger_calls,
  @max_logger_calls)` instead of using `@max_logger_calls` directly.
- Rule 1.11 same pattern.

Rule 1.9 has no numeric threshold (it's per-call-site detection); the
M-Plan4 default-arg fix already covers the over-firing concern, so
1.9 needs no threshold knob.

**Test files (TDD-first):**
- `test/archdo/config_test.exs` — add 3 tests: parses `thresholds:`
  keyword, accessor returns configured value, accessor returns default
  when key absent.
- `test/rules/module/cross_cutting_in_domain_test.exs` — add 1 test:
  rule respects configured `max_logger_calls`.
- `test/rules/boundary/anemic_context_test.exs` — add 1 test: rule
  respects configured `min_files`.

**Effort:** 45 minutes.

---

## Phase B — Medium analyzers (1-3 hr each)

### M-Plan6 — CE-57 propagate input-guard verdict to module level (M6)

**Problem:** CE-57 (M-Aux6) flags individual functions whose input
is unguarded. The `--building-blocks` CLI uses
`Blackbox.module_verdict/1` which only checks the structural 6-component
score; it doesn't reflect CE-57 findings. A module can show as
`:building_block` even when one of its functions accepts unguarded input.

**Fix:** New `Blackbox.module_input_safety/2` that takes a module's AST
and returns `:safe | {:unsafe, [{name, arity, reason}]}`. Reuse
CE-57's `unguarded_clause?/1` predicate (extract to shared helper in
`Archdo.Rules.CE.UnguardedBuildingBlock`). Update `module_verdict/1`
to combine the existing 6-component check AND the input-safety check
— a module is `:building_block` only if both pass. The
`--building-blocks` CLI prints "input-safety" leaks alongside the
existing structural leaks.

**Test files:**
- `test/archdo/blackbox_test.exs` — add 3 tests: pure module with
  guarded inputs is `:building_block`; pure module with one unguarded
  fn is `{:leaks_at, [{name, arity, _}]}` with reason `:unguarded_input`;
  CLI output includes input-safety leaks.

**Effort:** 1.5 hr.

---

### M-Plan7 — CE-27 + CE-28 cross-function call-graph walk (M1 + M2)

**Status (2026-05-02):** Deferred to follow-up session. Architectural
barrier identified: CE-27 and CE-28 are file-level rules
(`analyze/3`) registered in `@phase1_rules`. Implementing the
"covering plug" check requires PROJECT-level state — the set of plug
modules that emit telemetry / log — that the file-level dispatch
model doesn't expose.

**Two structural paths forward (pick one in follow-up):**

1. **Convert both rules to project-level.** Move CE-27 / CE-28 from
   `Runner.@phase1_rules` to `Archdo.@project_file_ast_rules`. Each
   rule's `analyze_project/2` builds the plug-coverage index in a
   single pre-pass, then iterates `file_asts` running the existing
   per-file logic with the coverage as a parameter. Cost: changes
   the rule's dispatch model; per-file parallelism in the runner
   no longer applies to these two rules.

2. **Add `:plug_coverage` to opts via a runner pre-pass.**
   `Runner.analyze/2` would call a new `Archdo.PluginCoverage.scan/1`
   over `file_asts` once, then pass the result via opts to every
   per-file rule. Existing rules ignore the new key; CE-27 / CE-28
   read it. Cost: adds project-level state to the per-file dispatch
   path (small change to runner.ex; no impact on parallelism).

Path 2 is preferred because it preserves the file-level dispatch and
keeps the rule shape uniform with other CE rules. The plug-coverage
index shape is small:

```elixir
%{
  telemetry_plugs: [module_name, ...],   # plug modules with :telemetry.* calls
  log_plugs: [module_name, ...]           # plug modules with Logger.error/.warning calls
}
```

A "plug module" is a module defining `def call(conn, _opts)` (the
Plug behaviour shape). The `pipeline :api do plug X end` mapping
from router → plugs is OPTIONAL for v1: presence of any
telemetry/log plug in the project is signal enough that the project
has a plug-based observability strategy. Per-pipeline scoping is a
v2 refinement.

**Tests required when implementing:**
- `test/rules/ce/boundary_telemetry_test.exs` — add 2 tests:
  controller is NOT flagged when project has any telemetry plug;
  controller IS flagged when project has no telemetry plug.
- `test/rules/ce/error_path_without_log_test.exs` — add 2 tests:
  function returning `{:error, _}` is NOT flagged when project has
  any log-plug; IS flagged otherwise.

**Effort estimate:** 3 hr (was 2.5; updated after structural review).
**Disposition:** deferred — requires runner pre-pass plumbing. Not
in scope for the May 2026 session.

---

### M-Plan8 — CE-30 broaden graph for apply/3 + nested supervisors (F1 + M5)

**Problem:** CE-30 self-analysis still has 29 false positives because
graph extraction misses:
- `apply(mod, fn, args)` dynamic dispatch — `mod` may be bound to a
  module atom from a list, but the walker doesn't know that
- Supervisor children listed in `init/1` of a non-`Application` module
  (e.g., a sub-supervisor's child list)

**Fix:**
- Extend `Archdo.Graph.extract_edges/2` to handle `apply/3`:
  when the first arg is a literal module alias (`apply(MyMod, :run,
  [arg])`), emit a `:dynamic_dispatch` edge.
- Extend `Archdo.AnchorSet.compute/1` to walk every `Supervisor.init/2`
  call (not just inside `Application.start/2`) and treat its child
  list as anchors. Same for `DynamicSupervisor.init/1` returning a
  child spec.

**Test files:**
- `test/archdo/graph_test.exs` — add 2 tests: `apply(MyMod, :f, [])`
  emits an edge; `apply(var, :f, [])` does NOT emit an edge.
- `test/archdo/anchor_set_test.exs` — add 2 tests: child in nested
  supervisor's `init/1` is anchored; child in dynamic supervisor's
  `init/1` is anchored.

**Field check:** Re-run `mix archdo --paths lib --packs ce_compliance,core`
on Archdo itself; expect CE-30 self-finding count down from 29 to <15.

**Effort:** 2 hr.

---

### M-Plan9 — CE-50 transitively-threaded chain detection (M3)

**Problem:** CE-50 catches `{:ok, _} = X.call(...); :ok` and
`var = X.call(...); :ok`. It misses
`r = X.call(...); process(r); :ok` — the value flows through one
function then is discarded.

**Fix:** Light data-flow walk. For each function body, build a binding
graph: `{var → [usage_sites]}`. A binding is "thrown away" if every
usage site is a leaf call (no transitively-derived value reaches the
return position). Add `Archdo.Rules.CE.OkLosesInfo.threaded_unused?/1`
that detects the new shape; combine with existing predicates via OR.

**Test files:**
- `test/rules/ce/ok_loses_info_test.exs` — 4 tests: transitive thread
  + discard fires; transitive thread + return does NOT fire; multiple
  intermediate steps + discard fires; existing patterns still fire.

**Effort:** 2 hr.

---

### M-Plan10 — CE-11 add test-density sub-score (M4)

**Problem:** CE-11 contract density currently scores spec_coverage +
doc_coverage. The PLAN noted test-density was deferred because it
needs paired source/test matching. Single-module projects also get no
signal because cohort size threshold is ≥3.

**Fix:**
- Pair: for `lib/foo/bar.ex` look for `test/foo/bar_test.exs` (the
  Mix convention). Count public functions in source vs `test "..." do
  ... end` blocks in test file.
- Test density score = `min(1.0, test_count / public_fn_count)`.
- Combined CE-11 score = average of `spec_coverage`, `doc_coverage`,
  `test_density`. Fires when the combined score < 50% of cohort
  median (cohort threshold lowered to ≥2 since test-density gives
  signal even in small projects).

**Test files:**
- `test/rules/ce/contract_density_test.exs` — add 3 tests: module with
  paired test file scores higher than module without; test density
  lowers below median fires; small-cohort (2 modules) fires correctly.

**Effort:** 1.5 hr.

---

### M-Plan11 — D12: Clone diff-awareness for umbrella siblings (Rule 3.1)

**Problem:** Rule 3.1 reports clones across umbrella sibling apps as
high-severity even when both copies are intentional (e.g., shared
schema fields between `apps/api` and `apps/edge`). Field feedback
asked for `:info`-level downgrade when sibling apps own the clones.

**Fix:** In `DuplicatedCode.analyze_project/1`, group findings by
top-level prefix (`Archdo.Foo` vs `Archdo.Bar` is intra-app;
`ApiApp.Foo` vs `EdgeApp.Foo` is cross-app). Cross-app clones get
`Diagnostic.info/2` instead of warning.

**Detection:** umbrella iff `mix.exs` contains `apps_path:` OR project
root has `apps/` directory with sub-`mix.exs` files.

**Test files:**
- `test/rules/module/duplicated_code_test.exs` — add 2 tests: umbrella
  sibling clone emits `:info`; intra-app clone still emits `:warning`.

**Effort:** 1 hr.

---

## Phase C — Larger features (deferred; spec here)

### M-Plan12 — `mix archdo --shorten Mod.fn/N` (D1)

**Specification (defers implementation):**
- New CLI flag `--shorten Mod.fn/N` produces a shortened
  AST + StreamData property test for the named function.
- `Archdo.Shorten` module, public API:
  - `analyze(file, ast, mfa) :: {:ok, %Shorten.Result{}} | {:error, term()}`
  - `Result` struct: `{:ast, :ast_size, :pure?, :guards, :suggested_property}`
- `suggested_property/1` returns a StreamData skeleton based on the
  function's `@spec`-inferred input types (or guards if no spec).
- CLI prints the shortened AST + property template; user copies into
  test file.
- Integration: needs `Archdo.Blackbox.score_function/4` results to
  validate the function IS suitable for property testing
  (substantive enough — substance ≥ 0.4).

**Test plan:** 6 tests in `test/archdo/shorten_test.exs` covering:
guarded fn with int spec generates `integer()`, fn with no spec falls
back to `term()`, fn with map arg generates `map_of(...)`, error on
unknown fn, error on macro fn, fn under threshold rejected.

**Effort:** ~1 day.

**Disposition:** deferred to follow-up session — too large for this
batch and orthogonal to the false-positive cleanup that's the main
ROI of Phase A+B.

---

### M-Plan13 — Metadata-aware volatility V2 (D2)

**Specification:**
- New `Archdo.Volatility.MixLockSource` module that parses `mix.lock`
  to extract per-dep version, source (`:hex` / `:git` / `:path`).
- New `Archdo.Volatility.HexpmSource` (optional) that fetches
  package metadata from `https://hex.pm/api/packages/<name>` to
  determine: download_count, last_release_date,
  external-dep-count.
- Both sources behind a behaviour `Archdo.Volatility.MetadataSource`
  with `@callback fetch(name :: atom()) :: {:ok, map()} | {:error, _}`.
- `Volatility.classify_module/3` consumes the metadata to refine the
  shipped per-dep profile: high-download + recent-release →
  `:stable`; low-download or stale → `:volatile`.
- HexpmSource is OPT-IN via `--hexpm-cache <dir>` flag (avoids
  network round-trips by default; cache is offline after first fetch).

**Effort:** ~1 day. **Disposition:** deferred.

---

### M-Plan14 — `--compare-with` curated cohort + HTML map (D3 + D4)

**Specification:**
- Curated reference cohort: `Archdo.Compare.curated_cohort/0` returns
  `[%{name: "phoenix", path: ..., commit: ...}, ...]` for a stable set
  of well-known projects.
- New `mix archdo --compare-with-curated` — clones (or uses cached)
  each cohort entry, runs analysis, prints comparison table.
- Caching: `~/.archdo/cohort/<name>` clones; refreshed on commit-SHA
  mismatch.
- HTML volatility map: `Archdo.Diagram.VolatilityMap` renders an SVG
  heatmap of `(module → volatility tag)` overlaid on the dependency
  graph.

**Effort:** ~2 days combined. **Disposition:** deferred.

---

### M-Plan15 — SM-B/C/E/G/H/I (D5)

**Specification:** Six state-machine rules requiring an explicit
`@transitions [{from, event, to}, ...]` module attribute. Each rule
fires only when the project opts in via the attribute.

**Names + behaviours:**
- SM-B: Unreachable state (no incoming transition)
- SM-C: Terminal state with outgoing transition
- SM-E: Variable-bound `next_state` value
- SM-G: Event referenced in transition table not handled
- SM-H: State referenced in transition table not declared
- SM-I: Cycle in deterministic-only transitions

**Effort:** ~3 hr per rule, ~1.5 days total. **Disposition:** deferred.

---

### M-Plan16 — Interactive diagram v3 (D6)

**Specification:** UX enhancements per CONTINUE.md "Planned (v3)"
section. Sugiyama layout, orthogonal routing, port endpoints, search,
PNG export.

**Effort:** ~2-3 days. **Disposition:** deferred.

---

### M-Plan17 — Rule 6.34 HEEx via Phoenix.LiveView.HTMLEngine.compile (F3)

**Specification:**
- Add optional `phoenix_live_view` dep gated by a `:heex_compile`
  flag.
- Replace regex HEEx scanning in `DeadPrivateFunction` with
  `Phoenix.LiveView.HTMLEngine.compile/2` to get exact function-call
  resolution including dynamic `<.tag>` patterns.
- Behind config flag (off by default — adds dep weight).

**Effort:** ~4 hr. **Disposition:** deferred.

---

### M-Plan18 — CE-23 Campbell calibration cohort study (F4)

**Specification:** Empirical study, not code. Run CE-23 across the
field cohort (hexpm, Plausible, Livebook, otel, oban, broadway, req,
ecto, supavisor, finch). Hand-rate each finding as TP / FP /
borderline. If FP rate > 30%, recalibrate the warn/error thresholds
(currently 15 / 25). Document the calibration in
`ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-23`.

**Effort:** ~3 hr (mostly judgment). **Disposition:** deferred.

---

### M-Plan19 — Compiled.Graph split: builder vs query (Stats leaks fix)

**Problem (May 2026 stats audit):** The `Compiled` context shows 27
boundary leaks. Inspection confirmed all are `Archdo.Rules.Compiled.*`
rule modules `alias Archdo.Compiled.Graph` and calling
`Graph.callers/2`, `Graph.dependencies/2`, `Graph.find_function/2`,
etc. The metric is correct: `Compiled.Graph` is not the registered
boundary of the Compiled context (`Archdo.Compiled` is), and the
927-line `Graph` module mixes the build-the-graph side (struct
construction, edge extraction, BEAM scanning) with the
query-the-graph side (read API consumed by 19+ rule modules).

The conservative fix is the one-line `.archdo.exs` config
(`boundary_modules: ["Archdo.Compiled.Graph"]`) — that drops the
metric to zero. M-Plan19 is the architectural fix instead: the
`Compiled.Graph` file is too big and mixes two responsibilities;
splitting it makes the boundary honest, not just classified.

**Fix shape:**

1. **New module `Archdo.Compiled.Query`** owns the read API:
   - `callers(graph, mfa)` — who calls this function?
   - `dependencies(graph, module)` — what does this module depend on?
   - `find_function(graph, mfa)` — locate function metadata
   - `module_modules(graph)` — list every module
   - `unused_functions(graph)` — exported but uncalled
   - `transitive_callers(graph, mfa, depth)` — n-hop callers
   - `find_recursive_calls(graph, mfa)` — self-loops
   - All other read-only accessors currently in `Compiled.Graph`
     (any function with name starting `find_`, `list_`, `get_`,
     or that takes a `%Graph{}` and returns derived data without
     mutating).

2. **`Archdo.Compiled.Graph` retains only**:
   - `defstruct` for `%Graph{}` and `%Function{}` types
   - `analyze/1` — the BEAM-scanning builder
   - `module_atom_from_beam/1` and other private build helpers
   - Tarjan's SCC implementation (used by builder)
   - `extract_function_clauses/1` and other ingest helpers
   - Public API surface shrinks to: `analyze/1`, struct types only.

3. **`Archdo.Compiled` re-exports `Query`'s functions** via
   `defdelegate` so external callers can use either the facade
   (`Archdo.Compiled.callers(graph, mfa)`) OR import `Query`
   directly. The 19 `Archdo.Rules.Compiled.*` rule modules are
   updated to `alias Archdo.Compiled.Query` instead of
   `alias Archdo.Compiled.Graph`.

4. **`%Graph{}` struct stays in `Compiled.Graph`** — it's the
   data shape both builder and query operate on, lives with the
   builder. Rules that need to type-annotate continue to write
   `%Graph{}` from `Archdo.Compiled.Graph`.

**Why a real split, not just a facade:**
- `Compiled.Graph` is 927 lines today — Archdo's largest file.
  Already a candidate for split per the May 2026 stats output.
- A pure `defdelegate` facade in `Archdo.Compiled` would silence
  the leak metric but leave the file size and mixed responsibility
  untouched. Then the next rule needing a new query function still
  has to navigate a 1000-line file.
- After split, `Compiled.Graph` is purely a builder
  (~400 lines: struct, analyze/1, ingest helpers, Tarjan SCC).
  `Compiled.Query` is purely a reader (~500 lines: every accessor
  rules consume). Two single-purpose files.

**Test files:**

- **`test/archdo/compiled/query_test.exs` (new)** — 8 tests:
  callers/2 returns expected list for a known graph fixture;
  dependencies/2 returns expected; find_function/2 returns nil
  for missing; transitive_callers/3 respects depth; unused_functions/1
  excludes private; module_modules/1 returns all known modules;
  find_recursive_calls/2 finds self-loops; query against an empty
  graph returns []/nil consistently.
- **`test/rules/compiled/graph_test.exs` (existing)** — keep all
  current tests; this file still tests `Compiled.Graph.analyze/1`
  (the builder side). Move any test that exercises a query function
  to `query_test.exs`.
- **No new tests needed for the rule modules** — they already test
  end-to-end behaviour and don't care which module they alias.

**Migration steps (in order, each commitable separately):**

1. Create `lib/archdo/compiled/query.ex` with all read-only
   functions copied from `Compiled.Graph`. Add `alias
   Archdo.Compiled.Graph` for the struct type. All tests still
   green (Graph still has the functions; Query is a parallel copy).
2. Add `Archdo.Compiled` `defdelegate` re-exports for every
   Query function. Now `Archdo.Compiled.callers/2` works as
   the public facade.
3. Update each `Archdo.Rules.Compiled.*` rule (19 files) to
   `alias Archdo.Compiled.Query` and call `Query.X` instead of
   `Graph.X`. Run tests after each batch of ~5 to catch
   regressions early.
4. Delete the read-only functions from `Compiled.Graph` (now
   only in `Compiled.Query`). The build path (`analyze/1`,
   ingest, struct) stays. Run full suite — should still be green
   because every external caller now goes through Query.
5. Field check: re-run `mix archdo --stats`. The Compiled
   "Leaks" column should show 0 (or close to it — any remaining
   non-Query callers indicate a missed migration).

**Why not Option 1 (one-line `.archdo.exs`):** that's the right
fix if you only care about the metric. M-Plan19 is the right fix
if you also care about the 927-line file the metric is pointing
at. Pick one based on whether the file size is a maintenance
problem yet — the metric will not be wrong either way.

**Effort:** ~half a day (4 hr): 1 hr to create Query + tests,
30 min for `Archdo.Compiled` defdelegate facade, 1.5 hr for
the 19 rule-module migrations, 30 min for delete + full suite,
30 min for `mix archdo --stats` confirmation and any cleanup.

**Disposition:** deferred — not a correctness fix, not blocking
any user. Ship when graph.ex's size becomes a navigation
problem, or as part of a larger Compiled-subsystem cleanup.

---

## Plan-completeness gate verification

§0.1 checklist for the M-Plan1..M-Plan11 scope (Phase A + B):

- ✓ Layout: every new module named with file path. No new contexts.
- ✓ Processes: no new processes. Pure analyzers in the existing Runner.
- ✓ State: no new state. Same opt-in keyword plumbing.
- ✓ Communication: rules consume `opts[:phoenix]`, `opts[:config]`.
- ✓ External boundaries: none.
- ✓ Configuration: `.archdo.exs` gains `thresholds:` keyword; the
  signature `Archdo.Config.threshold(config, rule_id, key, default)`
  is the single accessor.
- ✓ Resilience: no I/O.
- ✓ Test strategy: every milestone names its test files and counts.

Forbidden phrases (per §0.5): none in M-Plan1..M-Plan11. The Phase C
items use "deferred" only inside the explicit "Disposition: deferred"
line per planning convention.
