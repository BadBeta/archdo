# Architectural Change Economy Tests for Archdo

A proposal for a sibling rule category to **Indirection Economy** — **Change Economy** — that detects places where structure makes change, extension, or testing harder than it should be, *or* where substitutability is missing exactly where the volatility of the surrounding context demands it. All rules are fully static and require no git history, so they are usable on fresh, mid-life, and legacy codebases alike.

This document is a companion to `architectural_simplification_tests_archdo.md`. The two packs together form a complementary diagnostic: Indirection Economy flags abstractions that aren't pulling their weight; Change Economy flags places where the codebase will resist change, hide volatility, or punish testing. Both packs depend on a precise distinction between two properties that the word "flexibility" usually conflates — see §1.1 below.

---

## 1. Motivation

The orthodox dimensions of architectural quality — easy to maintain, easy to change, easy to extend, easy to test — all depend on properties that *most of the time* align with simplicity, not against it. A simple, well-named, low-coupling, high-cohesion module is the most changeable, most extensible, and most testable shape available.

But "flexibility" hides a real ambiguity that this pack must clear up before its rules make sense.

### 1.1 Two kinds of flexibility

Two distinct properties get called by the same name. Conflating them produces an apparent paradox in any volatility-driven framework, including this one. The proposal therefore distinguishes them sharply and uses the precise terms throughout:

**Changeability (Flexibility-1)** — the cost of modifying code when requirements change. Cheap when functions are pure, modules are cohesive, coupling is low, names are good, contracts are documented, tests are fast. **Wanted everywhere** in the codebase. Pure stable code provides Changeability *for free* — simplicity itself is the mechanism.

**Substitutability (Flexibility-2)** — the cost of swapping one implementation for another without modifying callers. Provided by behaviours, protocols, configurable adapters, dependency injection, Mox-style ports. **Wanted only where it solves a real problem**: testing a module that depends on external state (test seam), or insulating callers from change in a vendor API or external system (insulation layer). Carries real cost — one more concept to navigate, one more layer to read.

The two properties have very different cost/benefit profiles:

| Property | Where wanted | Provided by | Cost paid |
|---|---|---|---|
| **Changeability** | Everywhere | Simplicity, cohesion, low coupling, contracts | None — it's the natural state of well-written code |
| **Substitutability** | Volatile boundaries only | Abstraction layers (behaviours, protocols, adapters) | One concept of indirection per added seam |

The two are not in tension with each other. They occupy different parts of the codebase. The framework's recommendations follow directly:

| Code zone | Changeability | Substitutability |
|---|---|---|
| **Pure stable core** | Maximal (free, from simplicity) | Not needed — pure code has no testability problem and no external-change-driver to insulate against |
| **Volatile boundary** | Preserved *for the rest of the codebase*, achieved *via* Substitutability containing the volatility | Earned — provides test seams and absorbs vendor / protocol / external drift |
| **Mixed module** | Compromised — see CE-4 | Often cannot be invested cleanly because the module conflates concerns |

Stable code being "less flexible" means *less Substitutable* — and that is the correct shape, because Substitutability solves problems stable code doesn't have. Stable code retains full Changeability through simplicity alone. The Substitutability layer at a volatile boundary doesn't make the volatile module itself more changeable or testable — it makes everything *around* it changeable and testable, by containing the volatility behind a stable interface.

Restated as one rule:

> Pay for Substitutability where it converts a hard testability or insulation problem into an easy one. Pure stable code has no such problem to solve, so Substitutability is overhead there. Volatile boundary code has the problem intrinsically, so Substitutability is the minimum cost to recover, for the rest of the codebase, the testability and insulation that pure code has for free.

### 1.2 How the two packs divide the work

Indirection Economy and Change Economy split the territory cleanly along this distinction:

- **Indirection Economy** enforces *don't pay for Substitutability that isn't earning its keep*. Catches speculative pluggability, single-implementor behaviours, rename wrappers, linear-only call chains.
- **Change Economy** enforces three things:
  1. *Do pay for Substitutability where the volatile context demands it* (Group A — volatility/Substitutability matching)
  2. *Don't introduce structural Changeability impediments anywhere* (Groups B–E — testability, information hiding, contracts, irreversibility, extraction)
  3. *Don't pay twice for Substitutability the framework already provides* (Group F — framework-aware policy). When Ecto.Repo, Phoenix.PubSub, Oban, or OTP primitives already supply a working test seam and vendor insulation, wrapping them in a project-defined behaviour is double abstraction.

Together the two packs form a closed loop. IE forces every Substitutability investment to justify itself. CE forces investments to appear where the kind of code demands them, forces the rest of the codebase to remain Changeable through simplicity rather than through abstraction, and forces respect for the framework's pre-existing abstractions instead of re-implementing them.

### 1.3 Why volatility is the right axis for Substitutability

The genuine architectural tension is not simplicity vs flexibility but:

> **Specialization** (code shaped exactly for the current task) vs **Generalization** (code shaped for a class of tasks).

Both fail when the future doesn't match prediction. The diagnostic question is: are the codebase's Substitutability investments concentrated where change is *likely* (volatile boundaries), absent where it isn't (stable cores), and is the codebase free of Changeability impediments throughout?

In a codebase without git history, "where is change likely" cannot be measured directly. Two static substitutes recover most of the value:

1. **Volatility presumption from kind-of-code.** Modules that touch I/O, third-party APIs, hardware, or external protocols are *presumed volatile* (intrinsically hard to test, and at common-case I/O boundaries also high in change probability). Modules of pure domain logic are *presumed stable* (intrinsically easy to test, and typically low in change probability at the interface level). The presumption is a heuristic and explicit markers let authors override it where the kind-of-code signal misleads.
2. **Comparative scoring against a reference cohort.** Running the same metrics on Phoenix, Ecto, Oban, Broadway, Tesla gives a calibrated absolute baseline. Outlier scores in either direction are findings.

These two mechanisms together replace the trend-based analysis that history would otherwise provide.

### 1.4 Honest limitation of the volatility heuristic

The volatility classification used by Group A rules is really a proxy for **test difficulty** (does the code touch external state, time, randomness?) that we use as a proxy for **change probability** (is the requirement likely to evolve?). At I/O boundaries the two coincide; HTTP clients are both hard to test in isolation *and* prone to vendor drift. They can dissociate:

- A complex pure algorithm can be hard to test exhaustively (high test difficulty in the property-coverage sense) yet very stable in its interface.
- A simple business rule can be trivially testable yet evolve every quarter as policy changes.

The framework cannot distinguish these cases statically. Author overrides (`@archdo_volatility :stable | :volatile | :mixed`) and path overrides (`stable_paths`, `volatile_paths`) exist exactly so the framework can be corrected when the heuristic mis-applies. The classifier's output is reported in every CE finding so reviewers can validate the input before evaluating the output.

---

## 2. Design principles

Inherited from the Indirection Economy pack, with one addition specific to Change Economy:

1. **Structural, not heuristic** (deterministic predicates).
2. **Falsifiable by construction** (each rule names what would make it not fire).
3. **Explicit exemptions over silent ignores** (markers, not deletions).
4. **One-line action** (every finding maps to a concrete fix).
5. **Auto-fix only when semantically safe** (most CE rules are review-required).
6. **Reason-bearing suppressions** (`# archdo:allow CE-X reason: ...`).
7. **Volatility-classification as first-class config.** Because Change Economy depends on classifying modules as volatile, stable, or mixed, that classification must be inspectable, overridable, and stable across runs. A module's volatility classification is reported alongside any CE finding so the reviewer can verify the predicate's input.

---

## 3. Volatility classification — the foundation

Five of the rules below depend on classifying each module as **volatile**, **stable**, or **mixed**. The classification is computed once per analysis run and shared across rules.

### 3.1 Algorithm

A flat "imports any volatile primitive → module is volatile" rule is too coarse. Some dependencies are extremely stable (`:crypto`, `Jason`, `Decimal`); others churn aggressively (vendor SDKs, HTTP middleware ecosystems). The classifier therefore uses a **per-dependency volatility profile**.

#### Two dimensions of stability

Before the algorithm, one principle that determines what tags actually mean.

A dependency's stability has two independent axes:

- **Spec stability** — the contract the code works *with*. Long-deliberated, versioned, backward-compatibility-preserving specifications: IETF RFCs, W3C recommendations, ISO / IEEE / ITU standards, NIST FIPS, OTP design principles, long-stable de facto standards (CommonMark, Semver, POSIX). Standards-based contracts are stable for decades.
- **Library stability** — the implementation you import. The library has its own version trajectory regardless of the spec it implements. A v0.x library implementing RFC 3986 is still pre-1.0 at the API surface level.

A dependency is **fully stable** only when both axes are stable. A standards-implementing library at maturity qualifies (`URI`, `Jason`, `:crypto`, `Base`). A standards-implementing library at v0.x is spec-stable but library-volatile — the metadata-aware refinement (item 3 below) catches this. The actionable rule:

> Stability flows from the most-volatile thing you depend on. A standardized protocol used through a churning transport library is dominated by the transport's volatility. Standardization helps the classification only when the library wrapping the standard has itself settled.

A second corollary: some modules are **dual-purpose** along this axis. `DateTime` is `:stable` for ISO 8601 parsing but `:non_deterministic` for `utc_now/0`. `:inet` is `:stable` for `parse_address/1` / `ntoa/1` but `:non_deterministic` for socket operations. The classifier handles these at call-site granularity (item 2 below).

#### Algorithm

For each module `M`:

1. **Per-dependency volatility profile.** A configurable list maps each dependency / primitive to one of four tags:
   - `:stable` — narrow surface, long-stable, rare breaking change. Includes both *intrinsically narrow* libs and *standards-implementing libs at maturity*. Examples:
     - **Stdlib & BEAM:** `:lists`, `:maps`, `:erlang`, `:string`, `:gen_event`, `:gen_statem`, `Supervisor`, `Registry`, `Phoenix.PubSub`, `Ecto.Query`
     - **Standards-implementing (mature):** `URI` (RFC 3986), `Base` / `:base64` / `:base32` (RFC 4648), `:crypto` for standard algorithms (NIST FIPS, IETF), `:zlib` (RFC 1950/1951), `:public_key` cert handling (X.509, PKCS), `Jason` / `Poison` (RFC 8259 JSON), `Decimal` (IEEE 754), `Calendar.ISO`, `DateTime.from_iso8601/1` (ISO 8601 parsing), `UUID` libs at v1+ (RFC 4122), MIME libs (RFC 6838)
   - `:stable_with_test_seam` — stable framework abstraction that already provides a test seam. Triggers Group F policy (CE-15 fires on wrappers; CE-2 exempts callers). Examples: `Ecto.Repo` (Sandbox), `Oban` (Oban.Testing), `Task.Supervisor` (start_supervised), `GenServer` (start_supervised + direct call).
   - `:volatile` — vendor-driven or protocol-driven surface drift expected. Examples: `Tesla`, `Finch`, `Req`, `HTTPoison`, `Mint`, `Plug.Conn`, modules matching `~r/_sdk$/`, `~r/^ex_aws/`, vendor SDKs by name.
   - `:non_deterministic` — primitives that introduce a testability concern rather than a vendor-drift concern. Examples: `DateTime.utc_now/0`, `:erlang.system_time/*`, `:rand.*`, `Process.send_after/4`, `make_ref/0`, `File`, `Path`, `System`, `:os`, `:filelib`, `:ssl` socket operations, `:gen_tcp`, `:gen_udp`. Treated as volatile for classification purposes; surfaced separately for CE-5.

   Defaults are shipped in Archdo; users override via `.archdo.exs` `dependency_volatility`. Pattern entries (`{~r/regex/, :tag, "rationale"}`) are supported alongside exact module names. Each entry carries a rationale string surfaced in findings so reviewers can see *why* the tag was assigned.

2. **Call-site granularity for dual-purpose modules.** A small set of modules expose both stable (data-shape) and non-deterministic (execution) operations. The classifier resolves these at the call site, not the module import:
   - `DateTime` — `from_iso8601/1`, `to_iso8601/1`, `to_string/1`, `compare/2`, arithmetic over given values: `:stable`. `utc_now/0`, `now/1`: `:non_deterministic`.
   - `:inet` — `parse_address/1`, `ntoa/1`, `parse_ipv4_address/1`, `parse_ipv6_address/1`: `:stable`. `getaddr/2`, `gethostbyname/1`, socket operations: `:non_deterministic`.
   - `:calendar` — date arithmetic, conversions: `:stable`. `local_time/0`, `universal_time/0`: `:non_deterministic`.
   - User-extensible via `.archdo.exs` `dual_purpose_modules`, each entry a `{module, %{stable_funs: [...], non_deterministic_funs: [...]}}` map.

   Modules not in the dual-purpose list use a single tag per the per-dep profile.

3. **Optional metadata-aware refinement.** With `dependency_volatility_strategy: :metadata_aware`, the classifier reads `mix.lock` and Hex.pm metadata to refine the profile:
   - Pre-1.0 deps (`0.x.y` versions) → bumped one tag toward volatile (a `:stable` defaults dep at v0 reverts to `:volatile` — *spec stability does not override library churn*)
   - Deps with ≥ 2 majors in the past 24 months → bumped one tag toward volatile
   - Deps at v1+ with no release in 18+ months *and* no known abandonment → tag preserved (mature stable; abandoned deps need manual review)
   - Local / umbrella siblings (`path:` deps in `mix.exs`) → default `:stable`, override per-dep as needed

   With `:static_only` the classifier uses the explicit profile list without metadata access.

4. **Volatile call density.** Count call sites in `M` whose target is `:volatile` or `:non_deterministic` (after metadata refinement and call-site resolution), divided by total call sites in `M`. Calls into `:stable_with_test_seam` deps do not count toward density — they are covered by Group F, not Group A.

5. **Path-based override.** Modules under paths listed in `.archdo.exs` `volatile_paths` (e.g., `lib/myapp/integrations/**`) are unconditionally volatile; modules under `stable_paths` are unconditionally stable.

6. **Author override.** A module attribute `@archdo_volatility :stable | :volatile | :mixed` short-circuits the heuristic.

7. **Classification:**
   - `volatile_density ≥ 0.40` or path/author override `:volatile` → **volatile**
   - `volatile_density ≤ 0.05` and not path/author override → **stable**
   - Otherwise → **mixed**

### 3.2 Exposure

The classification is exported in `mix archdo --metrics` as a per-module column and emitted in every CE-* finding's evidence section. Reviewers can sanity-check the input before evaluating the output.

### 3.3 Mixed-modules policy

A "mixed" module is itself a finding (CE-4 below). Mixed status indicates a module that is neither cleanly a boundary nor cleanly a domain core — it's most often a candidate for splitting along the I/O seam.

---

## 4. The rule pack — Change Economy

Fifty-six rules in fifteen groups. Each: **detects**, **algorithm**, **why this hurts change/extend/test**, **suggested fix**, **exemptions**, **auto-fix**.

### Group A — Volatility / Substitutability matching (4 rules)

The core question: is **Substitutability** (Flexibility-2) concentrated at volatile boundaries (where it earns its keep as test seam and insulation) and absent from stable cores (where it would be overhead)? **Changeability** (Flexibility-1) is preserved across both zones, but achieved differently — via simplicity in stable code, via the Substitutability layer in volatile code.

#### CE-1 — Volatile module with hardcoded dependencies

**Detects:** a volatile module that calls another volatile primitive directly, with no behaviour-based seam, no Mox port, and no injection of the dependency.

**Algorithm:**
1. For each volatile module `M`:
   - Collect outgoing volatile calls (calls to volatile primitives).
   - For each, check whether the target is reached via:
     - A `@behaviour`-bound dispatch that has a `Mox.defmock` in `test/`, or
     - A function parameter (dependency injection), or
     - An explicit `Application.get_env`-bound module slot with a corresponding mock.
2. If at least one outgoing volatile call has none of those mediations, fire on the call site.

**Why it hurts:** the module is in the volatile zone — Substitutability is the only mechanism that buys test seam and vendor-drift insulation here, and it's missing. Tests cannot exercise the module without real I/O; the dependency cannot be swapped. Result: brittle tests, slow tests, or no tests at all.

**Fix:** introduce a behaviour for the external dependency, define a `Mox.defmock` in `test/`, route the call through the behaviour. Or pass the dependency module as a parameter / option.

**Exemptions:** module marked `@archdo_volatility :stable` (override the classification); call site marked `# archdo:allow CE-1 reason: integration test exercises this real`.

**Auto-fix:** No (refactor, not mechanical).

---

#### CE-2 — Volatile boundary lacks abstraction layer

**Detects:** a volatile module exposed to multiple non-volatile callers without any behaviour/protocol/configurable-adapter layer between them.

**Algorithm:**
1. Identify volatile modules with ≥ 2 distinct non-volatile callers.
2. For each, check whether *any* of the callers reaches `M` through an abstraction (behaviour, protocol, or `Application.get_env`-bound module slot).
3. If zero callers go through an abstraction, fire on `M`.

**Why it hurts:** when the external dependency changes (API version, vendor swap, deprecation), every caller is affected. The Substitutability layer is the insulation that absorbs external change without ripple — and it's missing exactly where the volatility presumption says it earns its keep.

**Fix:** introduce a behaviour `M.Adapter`, route callers through it, register the current implementation as the default. This is one of the few places where a single-implementor behaviour is justified — Substitutability earns its keep through the test seam and insulation it provides at the volatile boundary. Authors should suppress IE-1 here with `reason: volatile boundary, see CE-2`.

**Exemptions:** the module *is* itself a thin internal helper (single caller); the volatility classification was overridden manually; **the volatile target is a framework-provided abstraction with its own test seam** (Ecto.Repo with Sandbox, Phoenix.PubSub with testing helpers, Oban with Oban.Testing, OTP primitives with start_supervised) — Substitutability is already provided, see CE-15 for the inverse policy.

**Auto-fix:** No.

---

#### CE-3 — Stable core with abstraction density above codebase median

**Detects:** a stable module that contains behaviours, protocols, configurable adapters, or injection points at higher density than the codebase median.

**Algorithm:**
1. Compute per-module `abstraction_density(M) = (behaviours + protocols + configurable_slots + injected_dependencies) / public_function_count`.
2. Compute the codebase median of `abstraction_density`.
3. For each stable module with `abstraction_density(M) > 2 × median`, fire.

**Why it hurts:** Substitutability is being paid for in the part of the system that doesn't need it. Pure stable code already has full Changeability through simplicity alone — adding behaviours, protocols, or configurable adapters here gives nothing extra and adds concepts the reader must navigate. This is the inverse of CE-2: Substitutability wasted on stable code, while volatile boundaries may go unprotected.

**Fix:** review each abstraction in the module against IE-1 / IE-2 / IE-7. Most will fail and should be inlined.

**Exemptions:** module marked `@archdo_volatility :volatile` or `:mixed` (classification override); module is a documented public extension surface (`@archdo_extension_point true`).

**Auto-fix:** No (each abstraction needs case-by-case review).

---

#### CE-4 — Mixed-volatility module (split candidate)

**Detects:** a module classified as mixed — neither a clean I/O boundary nor a clean domain core.

**Algorithm:** classification result is `:mixed` (volatile call density between 0.05 and 0.40).

**Why it hurts:** mixed modules sit between the two regimes and get neither benefit. They're hard to test (have I/O, can't be pure-tested) so the pure parts pay a Substitutability cost they wouldn't need on their own; they're hard to substitute cleanly (have domain logic, swapping the I/O substitutes more than just I/O) so the volatile parts can't get a clean test seam either. Every change to the I/O parts forces re-testing the domain parts and vice versa — neither Changeability nor Substitutability is preserved.

**Fix:** split along the I/O seam. The pure logic moves to a stable sibling module; the I/O retains the original module name (or vice versa) and calls into the pure module. This is the canonical refactor that converts a mixed module into one stable + one volatile.

**Exemptions:** module is a small adapter where I/O density would be near-50% by nature (e.g., a CSV importer that parses *and* reads). Marker `@archdo_split_unjustified reason: ...`.

**Auto-fix:** No (semantic refactor).

---

### Group B — Testability hazards (5 rules)

Direct testability metrics, all static. Includes complexity rules because complexity directly drives the test case count needed for adequate coverage — a function's state space grows with cognitive load, not with line count.

#### CE-5 — Non-deterministic call in stable module

**Detects:** a stable-classified module containing direct calls to non-deterministic primitives (`DateTime.utc_now/0`, `:rand.*`, `Process.send_after/4`, `make_ref/0`, `:erlang.system_time/*`, etc.).

**Algorithm:** AST scan of stable modules for the call set defined in §3.1. Each call site is a finding.

**Why it hurts:** every such call seeds a future flaky test or forces test-time monkey-patching. The call also retroactively makes the module mixed — the volatility classification heuristic catches it, but the rule fires earlier as a direct diagnostic.

**Fix:** inject the non-deterministic primitive. Standard Elixir patterns:
- A clock module behaviour with `Mox.defmock` for tests
- A `random` parameter or option threaded through public functions
- For supervised time effects, a `:scheduler` module bound via config

**Exemptions:** call site marked `# archdo:allow CE-5 reason: ...`; module marked `@archdo_volatility :volatile`.

**Auto-fix:** No (refactor pattern, not one-liner).

---

#### CE-6 — Test isolation hazard

**Detects:** test code that depends on shared global state — making tests order-dependent, flaky, or non-async-safe.

**Algorithm:** in `test/`, scan for:
- `Application.put_env/3` without `on_exit` cleanup
- Named processes started via `start_link(name: :foo)` without ExUnit setup
- ETS tables created at module level (not per-test setup)
- `:meck` or `Mock` library usage (incompatible with `async: true`)
- Persistent file writes outside `tmp_dir` / `System.tmp_dir`
- Direct mutation of `:persistent_term` in tests

Each is a finding.

**Why it hurts:** tests cannot be `async: true`, the suite gets slower as it grows, and order-dependent flakes accumulate.

**Fix:** scope state per-test (setup / `on_exit`); use `Mox` instead of `:meck`; use `tmp_dir`; use `start_supervised`.

**Exemptions:** integration test files explicitly tagged `:async_unsafe`.

**Auto-fix:** Some — `Application.put_env` followed by missing `on_exit` cleanup can be fixed mechanically; others are refactors.

---

#### CE-7 — Property-test-able function lacks property test

**Detects:** a public function with a `@spec` describing pure shapes (in → out, no side-effect types) that has no corresponding StreamData property test.

**Algorithm:**
1. Collect public functions with `@spec`.
2. Filter to those whose spec is "pure-looking": input types are concrete (`integer()`, `String.t()`, structs, lists, maps, tuples) and the output type is similarly concrete; no `IO.t`, `pid()`, `reference()`, no side-effecting return shapes.
3. For each, search `test/` for a `property` block (from `ExUnitProperties`) that calls the function.
4. If absent, fire as informational severity.

**Why it hurts:** the function is a free property-testing opportunity that's been left on the table. Property tests give 10–100× the input coverage of example-based tests at low cost.

**Fix:** add a property test using `StreamData`. Often a 5-line addition.

**Exemptions:** function marked `@archdo_no_property reason: ...`; spec is technically pure but the function reads external state via shared module attribute (rare).

**Auto-fix:** can generate a stub property test (informational level — author writes the property).

---

#### CE-23 — High cognitive complexity public function

**Detects:** a public function whose **cognitive complexity** (Campbell, SonarSource 2018 — distinct from McCabe cyclomatic) exceeds a threshold. Cognitive complexity tracks human reading difficulty rather than graph paths: it does not penalize flat dispatch (large `case`, multi-clause functions) but penalizes nesting linearly with depth and adds weight for broken control flow.

**Algorithm:** AST walk per Campbell's rules:
- `+1` per control-flow structure (`if`, `case`, `cond`, `with`, `try`, `for` with `:reduce`)
- `+nesting_depth` per nested control-flow structure (so a `case` inside an `if` inside a `case` adds `1 + 2 + 3 = 6` rather than `3`)
- `+1` per logical operator (`&&`, `||`) chained beyond the first
- `+1` per recursion edge (calls to self with structural change)
- Multi-clause function definitions count as **one** `case` structure unless the clauses contain nested logic — this is the key Elixir-specific calibration that prevents over-firing on idiomatic dispatch.

Default threshold: `cognitive > 15` fires warning; `cognitive > 25` fires error in `--strict` mode. Both tunable per `.archdo.exs`.

**Why it hurts:** the function is hard to read, hard to modify safely (every change risks one of the implicit branches), and hard to test exhaustively — the test-case state space grows with cognitive load. This is a Changeability *and* testability impediment in one.

**Fix:** extract sub-functions to flatten nesting; convert nested `case` / `if` to multi-clause function dispatch; replace twisty `with` chains with explicit early-return helpers; collapse logical compounds into named predicates.

**Exemptions:** function marked `@archdo_complex_ok reason: ...`; function is generated code (parsers, state machine tables, schema-derived).

**Cross-reference:** when CE-23 fires, also evaluate CE-24 — if cyclomatic complexity is far lower than cognitive, the function is a *twisty hidden* refactor target (the worst kind); if cyclomatic is comparable to cognitive, it's uniformly complex (still bad, but not surprising).

**Auto-fix:** No (refactor is design-dependent).

---

#### CE-24 — Cyclomatic / cognitive complexity shape mismatch

**Detects:** functions where cyclomatic and cognitive complexity disagree by more than `2×` in either direction. The disagreement carries information neither metric provides alone:

- **Twisty-nested (cognitive > 2× cyclomatic, cognitive ≥ 10)** — fires **warning**. The function looks innocent by decision count but is hard to read because of nesting depth or broken control flow. This is the genuine refactor target that pure cyclomatic linting misses.
- **Idiomatic-dispatch (cyclomatic > 2× cognitive, cyclomatic ≥ 8)** — fires **informational**. The function has many decision points but they're flat dispatch (large `case`, multi-clause function with many heads, exhaustive `cond`). The dispatch is fine; cyclomatic is over-counting.

**Algorithm:** compute both cyclomatic and cognitive per function, compare ratios against thresholds, classify into one of four shapes:

| Shape | Cyclomatic | Cognitive | Action |
|---|---|---|---|
| **flat-dispatch** | High (≥ 8) | Low (< ½ cyclomatic) | CE-24 informational + auto-suppress cyclomatic-only rules at this site |
| **twisty-nested** | Low–moderate | High (> 2× cyclomatic, ≥ 10) | CE-24 warning + likely CE-23 finding |
| **uniform-complex** | High | High (within 2×) | CE-23 fires; CE-24 does not |
| **simple** | Low | Low | No finding |

**Why it matters:** lets the framework *promote* the missed-by-cyclomatic case (twisty-nested → real refactor target) and *suppress* the over-counted-by-cyclomatic case (flat-dispatch → idiomatic, leave alone). Without this rule, cyclomatic-only complexity rules over-fire on idiomatic Elixir and under-fire on the actual reading hazards.

**Cross-reference:** CE-24 informational findings should auto-generate a suppression for cyclomatic-only complexity rules at the same site, with reason `idiomatic dispatch — see CE-24`. This is the inverse of how CE-15 auto-suppresses IE-1 — same machinery.

**Auto-fix:** No.

**Exposure:** the `mix archdo --metrics` output gains three columns — `cyclomatic`, `cognitive`, `complexity_shape` — per function. The shape column is what reviewers read first, because it answers *what kind* of complexity is present, not just how much.

---

### Group C — Information hiding / change locality (3 rules)

Static substitutes for the change-amplification metric.

#### CE-8 — Internal struct in public API return type

**Detects:** a module that returns its own `%__MODULE__{}` (or another internal-looking struct) from public functions, with no opaque type or `@type` indirection.

**Algorithm:**
1. For each public function in `M`, examine `@spec` return types.
2. If a return type names a struct defined in `M` (or a sibling module not part of the documented public API), and the spec does not declare an `@opaque` type, fire.

**Why it hurts:** every caller now depends on the field set of the struct. Adding, renaming, or removing a field forces every caller to update. Information hiding is broken at compile time.

**Fix:** declare `@opaque t :: %__MODULE__{...}` and have the public API return `t()`. Provide accessor functions for the fields callers actually need. The struct definition becomes private; the accessor surface becomes the contract.

**Exemptions:** module is an Ecto schema (canonically struct-shaped, exempt by default); struct is documented as a public data shape (`@archdo_public_struct true`).

**Auto-fix:** No (introduces accessor functions — design decision).

---

#### CE-9 — Cross-module struct construction

**Detects:** a module `A` constructs `%B{}` directly when `B` defines its own struct.

**Algorithm:**
1. For each `%Struct{...}` literal in module `A` where `Struct ≠ A` and `Struct` is defined in the project (not stdlib).
2. Verify `B` does not export a constructor function (`new/1`, `build/1`, etc.).
3. Fire on the construction site.

**Why it hurts:** `A` is now coupled to `B`'s field set. Every internal change to `B`'s shape requires changes in `A`. The construction bypasses any invariants `B` would enforce in a constructor.

**Fix:** add `B.new/1` (or similar) that takes a map/keyword and returns `%B{}` with validation. Replace the literal in `A` with the constructor call.

**Exemptions:** Ecto changeset / query patterns where direct struct construction is idiomatic (`%MyApp.User{}` inside `Repo.insert` builders); construction site marked.

**Auto-fix:** Yes when `B.new/1` already exists — replace literal with constructor call. No when the constructor must be introduced.

---

#### CE-10 — Excessive public surface

**Detects:** a module with an unusually large public API given its size.

**Algorithm:**
1. For each module, compute `public_def_count(M)` excluding `@impl` callbacks.
2. Compute `body_loc(M)` (lines of all function bodies).
3. Fire when `public_def_count > 20` or `public_def_count / body_loc > 0.10` (more than one public function per 10 LOC of implementation).

**Why it hurts:** the module's external contract is broad; any internal change risks breaking distant callers; the module likely has poor cohesion (god module).

**Fix:** split along cohesion lines. Use LCOM-style analysis to find clusters of functions that share data dependencies; each cluster becomes a sub-module.

**Exemptions:** module is documented as a deliberate facade (`@archdo_facade true`); module is generated code (Ecto schema with many `field` declarations is fine — those aren't public functions).

**Auto-fix:** No.

---

### Group D — Irreversibility / contracts (2 rules)

Static substitutes for "have irreversible decisions been made carefully?"

#### CE-11 — Irreversible decision lacks contract density

**Detects:** a module representing a hard-to-reverse decision (database schema, supervision tree, public API) without specs, tests, or documentation at adequate density.

**Algorithm:**
1. Identify irreversible-decision modules:
   - `use Ecto.Schema` modules
   - Modules implementing `Supervisor` callbacks or returning `child_spec/1`
   - Modules listed in `mix.exs` `package.exports` or paths listed in `.archdo.exs` `public_api_paths`
2. For each, compute three sub-scores against the codebase median:
   - `@spec` coverage on public functions
   - Test density: test LOC per source LOC for this module's test file
   - `@moduledoc` presence + `@doc` coverage on public functions
3. Fire when *any* sub-score is below 50% of the codebase median.

**Why it hurts:** irreversible decisions are exactly where carelessness costs the most. A schema rolled out without specs becomes an unverifiable shape every consumer must guess at; a public API with no docs becomes everyone's reverse-engineering project.

**Fix:** raise the contract density at the site of the irreversible decision. Add `@spec`s to public functions, `@moduledoc` and `@doc`s to the module, and tests sufficient to anchor the contract.

**Exemptions:** module marked `@archdo_skip_contract_check reason: ...` (rare; usually means an internal-only schema not really irreversible).

**Auto-fix:** No (writes specs/docs/tests — author work).

---

#### CE-12 — Public API module with low @spec coverage

**Detects:** a module designated as public API where fewer than 80% of public functions have `@spec`s.

**Algorithm:**
1. Identify public API modules (same set as CE-11 step 1).
2. Count public functions and `@spec`s.
3. Fire when `spec_coverage < 0.80`.

**Why it hurts:** public APIs without specs cannot be Dialyzer-verified, callers must read source to understand contracts, and breaking changes are silent at compile time.

**Fix:** add `@spec`s to public functions. This is a finite, well-scoped task per module.

**Exemptions:** module marked `@archdo_specs_pending reason: ...` with a deadline.

**Auto-fix:** Can generate `@spec` stubs from Dialyzer success types when available — informational level only, author confirms the spec.

---

### Group E — Extraction trigger (1 rule)

The static analog of "rule of three."

#### CE-13 — Triplicate code shape (extraction candidate)

**Detects:** three or more near-identical code shapes in the codebase, suggesting an abstraction is justified.

**Algorithm:** Archdo already has Type-2 / Type-3 clone detection (rule 3.x). Extend it: when the *same* clone shape appears ≥ 3 times, promote the finding to "extraction candidate" with a stronger signal.

**Why it matters:** the rule of three is the standard heuristic for justified abstraction. Two could be coincidence; three is a pattern. Without git history we can't tell *when* the third instance arrived, but we can tell *that* it has.

**Fix:** extract a helper function, behaviour, or shared module that the three (or more) instances delegate to.

**Exemptions:** instances marked `# archdo:allow CE-13 reason: structural parallelism — diverging soon` (legitimate when three CRUD contexts look alike but will accrete distinct logic).

**Auto-fix:** No (extraction shape is design-dependent).

---

### Group F — Framework-aware policy (3 rules)

Where the framework (Ecto, Phoenix, Oban, OTP) already provides a Substitutability layer with a working test seam and vendor insulation, adding another layer is double abstraction — paying for what's already paid for. Group F enforces respect for the framework's existing abstractions and addresses two adjacent special cases that the volatile/stable axis handles poorly: external-facing data shape versioning, and Ecto schemas that have accreted domain behavior.

Group F also acts as the *exception list* for Group A: CE-2 should not fire on callers of framework-provided abstractions, because the abstraction is already there. CE-15 enforces the inverse policy — if you have wrapped Ecto.Repo / Phoenix.PubSub / Oban in your own behaviour, that wrapper is the finding, not the bare call.

#### CE-14 — External-facing data shape lacks versioning

**Detects:** a struct that crosses the codebase's external boundary (returned by Phoenix controllers via `render`, encoded for outbound HTTP, persisted as Oban job args, persisted as event-sourcing payload, broadcast over Phoenix.PubSub to external subscribers) without explicit versioning — neither a `version` / `__version__` / `schema_version` field, nor a versioned module namespace (e.g., `MyApp.API.V1.UserResponse`), nor an opaque external schema reference (e.g., a JSON Schema URI).

**Algorithm:**
1. Identify external-facing shapes:
   - Structs used as the data argument in `Phoenix.Controller.render/3`
   - Structs JSON-encoded via `Jason.encode!/1` / `Poison.encode!/1` in I/O code paths
   - Structs passed as `args` to `Oban.Worker.new/2`
   - Structs persisted as event-sourcing payloads (heuristic: modules under `events/`, `event_store/`, or implementing `Commanded.EventStore` patterns)
   - Structs published via `Phoenix.PubSub.broadcast/3` to topics not in the configured internal-only set
2. For each, check for a versioning marker (field or namespace).
3. If absent, fire (informational severity by default).

**Why it hurts:** the data shape is part of an external contract. Without explicit versioning, every consumer must guess at the implicit contract. Schema evolution becomes risky; backward compatibility becomes accidental; persisted payloads in event stores become un-evolvable. This is a Changeability impediment exactly because the shape will eventually need to evolve and the codebase has no machinery to evolve it safely.

**Fix:** introduce explicit versioning. Add a `version` field, move the struct under a versioned namespace (`V1`, `V2`), or document the external schema URI. For event-sourcing payloads, this is mandatory — once persisted, the shape is permanent.

**Exemptions:** struct marked `@archdo_unversioned reason: ...` (e.g., closed-system internal payload that happens to cross an HTTP boundary); struct deserialized from an upstream schema registry (versioning is upstream's responsibility); struct used only in transient PubSub messages with same-deploy producer and consumer.

**Auto-fix:** No (design decision).

---

#### CE-15 — Wrapper layer over framework-provided abstraction

**Detects:** a project-defined behaviour with a single (or zero) production implementation that wraps a framework primitive which already provides a working test seam and vendor insulation. The classic patterns: `MyApp.RepoBehaviour` wrapping `Ecto.Repo`, `MyApp.PubSubAdapter` wrapping `Phoenix.PubSub`, `MyApp.JobQueue` wrapping `Oban`.

**Algorithm:**
1. For each behaviour `B` in the project with `≤ 1` non-test implementor:
   - Identify the principal call target of the implementor (the framework primitive being wrapped — typically the most-called external module from inside the impl, weighted by call density).
   - Check whether the principal call target is a known framework-provided abstraction with a documented test seam:
     - `Ecto.Repo` → Sandbox provides isolation
     - `Phoenix.PubSub` → testing helpers + ExUnit assert_receive
     - `Oban` → Oban.Testing provides drain / inspect
     - `Task` / `Task.Supervisor` → start_supervised + Task.async/await
     - `GenServer` / `Agent` / `gen_statem` → start_supervised + direct call testing
   - User-extensible via `.archdo.exs` `framework_provided_abstractions` (each entry is `{module, test_seam_description}`)
2. If matched, fire on `B`.

**Why it hurts:** double abstraction. The framework already provides Substitutability — Sandbox for Ecto, testing helpers for PubSub/Oban — so the wrapper pays a layer cost for capabilities that already exist. The wrapper also typically fails to expose all the framework's features cleanly (transactions, multi, telemetry, supervisor integration), forcing leaky-abstraction escape hatches later. Both Changeability *and* Substitutability suffer: the wrapper makes change harder (one more layer to update on framework bumps) and adds nothing that direct calls + framework testing helpers don't already give.

**Fix:** delete the behaviour. Call the framework primitive directly from the previous callers. Use the framework's own test seam in tests.

**Exemptions:** wrapper exists to enforce a *policy* the framework doesn't (tenant scoping, read-replica routing, audit logging on every Repo call) — mark with `@archdo_policy_wrapper reason: ...`; wrapper exposes a domain-shaped interface (not a thin pass-through) and the framework primitive is genuinely a hidden detail (Hexagonal/Clean Architecture purist case, with at least one alternative implementation in plan or already present).

**Cross-reference:** when CE-15 fires on a behaviour, IE-1 should auto-suppress on the same behaviour (the diagnosis is CE-15, not IE-1). The fix is genuinely different: IE-1 says "wait for the second impl"; CE-15 says "the second impl will never come — the framework is already the abstraction, this wrapper is permanent overhead unless the policy/domain-shape exemption applies."

**Auto-fix:** No (deletes a public type with potentially many callers).

---

#### CE-16 — Ecto schema with significant domain behavior

**Detects:** a `use Ecto.Schema` module containing more than a configurable threshold of public functions that are not changesets, validations, or query helpers — i.e., the schema has accreted domain logic and is being asked to play two roles simultaneously.

**Algorithm:**
1. For each `use Ecto.Schema` module:
   - Collect public functions (excluding `__schema__`, generated callbacks, and `@impl` callbacks).
   - Classify each:
     - **Changeset / validation** — name matches `*changeset*` or returns `Ecto.Changeset.t()` per spec
     - **Query helper** — function uses `Ecto.Query` or returns a query
     - **Field accessor** — single-line returning a struct field
     - **Domain logic** — anything else
2. If `domain_logic_count > domain_logic_threshold` (default 3), fire.

**Why it hurts:** the schema is being asked to play two roles — persistence row mapper *and* domain entity. The two roles have different change drivers (database migrations vs business-rule evolution) and different lifetimes (a persisted row may outlive the domain entity that interpreted it; a domain entity may be backed by joins or computed values that aren't a single schema). Conflating them creates a CE-4-shaped problem at the data layer: every change to either role forces re-testing both, and both Changeability and information hiding (CE-8 / CE-9) suffer because the schema's field set is exposed wherever the domain entity is consumed.

**Fix:** extract the domain entity to a sibling module. Common pattern: `MyApp.Accounts.User.Schema` for the row mapper, `MyApp.Accounts.User` for the domain entity, with a `from_schema/1` translator at the context boundary. The schema becomes a thin row-mapper (fully exempt from CE-8 / CE-9 by Ecto convention); the domain entity owns the business behavior and gets full Changeability treatment.

**Exemptions:** small apps where the schema-as-domain-entity pattern is deliberately accepted — module marked `@archdo_schema_is_entity reason: ...`; schemas with only one or two domain functions (under threshold by default); generated schema modules.

**Auto-fix:** No (semantic refactor — splitting a module).

---

### Group G — Coupling shape (6 rules)

Coupling is not a single phenomenon. Page-Jones's connascence taxonomy ranks coupling forms by *strength*, *locality*, and *degree*: stronger connascence is acceptable only at shorter distance. Temporal coupling — connascence of execution — is a distinct hazard especially insidious in concurrent BEAM code where ordering bugs hide until production load. Group G targets these directly with structural predicates.

The actionable principle for connascence: **strength must be inversely proportional to distance**. Position-coupled arguments inside one private helper are fine; position-coupled arguments across module boundaries are a contract bug waiting. Magic-meaning coupling (`status == 1`) anywhere across a codebase is a Changeability impediment. Identity coupling via hardcoded process / ETS / persistent_term names creates implicit dependencies the supervision tree doesn't capture.

The actionable principle for temporal coupling: **execution order constraints must be encoded in types, supervision, or fused operations** — not left to documentation or convention.

#### CE-17 — Connascence of meaning across modules

**Detects:** the same magic value (number, string, atom) compared or assigned in ≥ 2 modules without a shared symbolic constant.

**Algorithm:**
1. Walk all modules; collect literal numbers, strings, and atoms appearing in comparisons (`==`, `!=`, pattern guards) or as right-hand sides of assignments to status-shaped fields (`status:`, `state:`, `kind:`, `type:`).
2. Group by literal value. For each value appearing in ≥ 2 modules, check whether a shared module attribute, behaviour-defined constant, or `defenum`-style accessor expresses it symbolically.
3. If absent, fire on each occurrence after the first.

**Why it hurts:** every consumer must know the magic value's meaning out-of-band. Renaming or renumbering forces a search-and-replace across modules; missing a site is a silent bug. Connascence of meaning across modules is one of the strongest forms of coupling at the longest distance.

**Fix:** introduce a shared symbolic constant — a module attribute, a `defenum`, or a behaviour-constant function — and replace literal references.

**Exemptions:** literal is a stable numeric constant (`0`, `1`, `-1`, status code `200`, port `80`/`443`); the literal is genuinely incidental (`Enum.take(list, 10)` where `10` is a local choice, not a cross-module contract).

**Auto-fix:** No (introducing the constant requires placement decision).

---

#### CE-18 — Connascence of position with high arity

**Detects:** functions with arity ≥ 4 (excluding pure recursive helpers) called from multiple modules.

**Algorithm:**
1. For each public function with arity ≥ 4:
   - Count distinct calling modules.
   - If ≥ 2, fire — argument order is now a cross-module contract.
2. Skip private functions and recursive accumulator helpers (heuristic: tail-recursive call to self with same arity).

**Why it hurts:** positional argument order is the strongest form of connascence of position. Across module boundaries, callers must remember which argument means what. Refactoring the function (reordering, adding a parameter) becomes a coordinated change across all callers.

**Fix:** convert to a struct argument or keyword options. `do_thing(a, b, c, d, e)` becomes `do_thing(%Request{a: a, b: b, c: c, d: d, e: e})` or `do_thing(a, opts)` with named options. Connascence of position is converted to connascence of name — much weaker.

**Exemptions:** function is a tightly-typed primitive (`Enum.reduce/4` shape); function marked `@archdo_arity_ok reason: ...`.

**Auto-fix:** No (signature redesign).

---

#### CE-19 — Connascence of identity via implicit naming

**Detects:** multiple modules reference the same hardcoded named-process / ETS table / `:persistent_term` key without a shared module attribute, registry helper, or behaviour exposing the name.

**Algorithm:**
1. Collect all uses of `name:` in `start_link`-shape calls, `:ets.new/2` first arg, `:persistent_term.put/2` and `.get/1` keys, `Registry.register/3`, etc.
2. Group by referenced atom. For each atom appearing in ≥ 2 modules with no shared accessor, fire on the references after the first.

**Why it hurts:** identity coupling is connascence at the strongest level. Every consumer must know the magic name; renaming requires a global search. Worse, the supervision tree typically doesn't express the dependency, so init order is implicit (compounds with CE-20).

**Fix:** introduce a single source for the name — a module attribute on the owning process module, a `name/0` function, or a Registry-based lookup helper that abstracts identity.

**Exemptions:** the name is a global singleton documented as the canonical identifier (e.g., `MyApp.PubSub`); references already go through a shared accessor.

**Auto-fix:** No.

---

#### CE-20 — Init-then-use without supervision dependency

**Detects:** a module starts a named process / ETS table / `:persistent_term` key at application start, and other modules call it, but the supervision tree does not enforce the start order.

**Algorithm:**
1. Identify resource-creators: modules calling `start_link(name: X)`, `:ets.new(X, ...)` at module level, `:persistent_term.put/2` in `application.ex` start.
2. Identify resource-consumers: modules calling functions on those resources (matched via CE-19's atom collection).
3. Inspect the supervision tree (`children/1` callbacks): is the creator listed *before* every consumer that runs as a supervised process?
4. If the consumer is invoked from request handlers (Phoenix, Plug) without an explicit ordering check, fire.

**Why it hurts:** temporal coupling left to convention. In normal startup the order works; under partial restart or supervisor child failure, the consumer may run before the creator, producing late-bound errors that don't reproduce in tests.

**Fix:** make the dependency explicit — either route consumer calls through a function that lazily creates the resource, list the creator earlier in the supervision tree, or use `Registry` so consumers wait until the name is registered.

**Exemptions:** the resource is created at compile time (`@table :ets.new(...)` in module attribute is not this pattern); supervisor explicitly orders the children with a comment.

**Auto-fix:** No (supervision-order edits require coordination).

---

#### CE-21 — Acquire/release pair without bracket helper

**Detects:** a module exposes paired public functions (`open/1` + `close/1`, `acquire/1` + `release/1`, `subscribe/2` + `unsubscribe/2`, `lock/1` + `unlock/1`) without a bracket-style helper (`with_X/2` taking a callback) that pairs them.

**Algorithm:**
1. Match public function pairs by name patterns: `open`/`close`, `acquire`/`release`, `start`/`stop`, `subscribe`/`unsubscribe`, `lock`/`unlock`, `connect`/`disconnect`, `checkout`/`checkin`.
2. For each pair, check whether the same module exposes a bracket function (a function whose body invokes the pair around a callback or `try/after`).
3. If absent, fire.

**Why it hurts:** every caller must remember to pair the calls and handle the cleanup branch on exception. Forgotten releases leak resources; orphaned locks deadlock. The pair is connascence of execution between two distant call sites.

**Fix:** add a bracket helper, e.g.
```elixir
def with_resource(arg, fun) do
  resource = open(arg)
  try do fun.(resource) after close(resource) end
end
```
Most callers can switch to the bracket; only callers needing manual control retain the raw pair.

**Exemptions:** pair is exposed for genuinely long-lived resources spanning multiple processes (`GenServer.start_link` + `GenServer.stop` for app-lifetime processes).

**Auto-fix:** Can generate the bracket helper as a stub for review.

---

#### CE-22 — Multi-call protocol on a single process

**Detects:** a process module (GenServer, gen_statem, Agent) exposes ≥ 2 public call entry points where one must precede the other, with the precondition documented in `@doc` rather than enforced by the type system.

**Algorithm:**
1. For each process module, collect public functions calling into the process (`GenServer.call`, `GenServer.cast`).
2. Scan their `@doc` strings for ordering markers: `"must call X first"`, `"after calling Y"`, `"requires X to have been called"`, `"only valid after"`, `"call this before"` (configurable phrase list).
3. If any matches, fire — temporal coupling encoded only in prose.

**Why it hurts:** the order constraint is a runtime contract enforced by documentation. New callers may miss it; existing callers may regress under refactoring. The contract has no compile-time check.

**Fix:** encode the ordering in the type system. Options:
- **gen_statem** — explicit states make the legal call set per state enforceable.
- **Fused operations** — collapse `connect/1` + `query/2` into `query_with_connect/2` at the public API.
- **Opaque handle types** — return a typed handle from the precondition call that the postcondition call requires (`{:ok, conn} = connect(...); query(conn, ...)`).

**Exemptions:** the protocol is genuinely OTP-callback-shaped (`init` precedes `handle_call`) and the prose merely documents that fact.

**Auto-fix:** No (refactor pattern).

---

### Group H — Concern composition (5 rules)

Cross-cutting concerns — logging, telemetry, authorization, transactions, retry, audit, idempotency — fundamentally don't belong to any one module. They cut across the system and accumulate at every interesting call site. AOP's diagnostic insight (independent of its weaving machinery) is twofold: a function whose body is mostly cross-cutting code has lost its domain intent in the noise, and a cross-cutting concern applied with divergent shape across many call sites becomes its own architectural smell.

Group H detects both, with structural predicates and Elixir-idiomatic fixes (bracket helpers, Plug pipelines, `:telemetry.span`, centralized telemetry taxonomies) — *not* macro-based decoration or runtime instrumentation.

#### CE-25 — Cross-cutting concern density per function

**Detects:** functions where calls to known cross-cutting modules make up more than a configurable percentage of the function body's expressions, with a minimum body size to avoid noise on tiny functions.

**Algorithm:**
1. Configure a list of cross-cutting modules per `.archdo.exs` `cross_cutting_modules`. Defaults:
   - Logging: `Logger`
   - Telemetry: `:telemetry`, `:telemetry_metrics`
   - Transactions: `Repo.transaction`, `Ecto.Multi`
   - Authorization: project-extensible (`Bodyguard`, `LetMe`, custom policy modules)
   - Audit: project-extensible (`AuditLog`, custom audit modules)
   - Retry / circuit breaker: `Retry`, `Fuse`, `:fuse`
2. For each function with body expression count ≥ 5:
   - Count expressions that are calls into cross-cutting modules.
   - Compute `density = cross_cutting_calls / total_expressions`.
   - If `density > 0.40`, fire.
3. Surface the cross-cutting modules involved in the finding so the reviewer sees *which* concerns are concentrating.

**Why it hurts:** the domain intent is buried under aspect noise. Adding a new aspect (rate limiting, idempotency tokens) requires editing every such function. Removing an aspect requires the same. The function reads as "do this set of cross-cutting things, and somewhere in the middle do the actual work." This is the inverse of CE-3 — the abstraction missing here is a *bracket helper* or a *Plug-like pipeline*, not a behaviour. Both Changeability (every aspect change ripples) and readability suffer.

**Fix:** extract a bracket or pipeline. Specific patterns:
- **Repo.transaction wrapping** — pull the transaction up the call stack, or rebuild the operation as `Ecto.Multi` so the transaction wraps a value rather than a function.
- **Logger / telemetry wrapping** — apply `:telemetry.span` at one consistent layer (the controller or the context entry, not both); remove inline `Logger.info` from the inner function.
- **Authorization gating** — route through a Plug at the controller boundary or a Policy module that gates entry to the context. Inline `if Authorize.allowed?` checks scattered through context functions are the smell.
- **Retry / circuit breaker** — wrap at the I/O boundary, not at the domain boundary.

**Exemptions:** function is *itself* the bracket helper (its job is to wrap concerns) — mark `@archdo_aspect_aggregator true`; function is at a documented composition layer (Plug call, Phoenix LiveView event handler) where cross-cutting code is expected.

**Auto-fix:** No (refactor is design-dependent).

---

#### CE-26 — Scattered cross-cutting concern

**Detects:** call sites of a cross-cutting module where the *call shape* (event name, log key, telemetry event, audit category) varies widely across the codebase in ways that are clearly synonyms — `"user_created"`, `"created_user"`, `"user.create"`, `[:user, :created]`, `[:users, :create]` all referring to the same conceptual event.

**Algorithm:**
1. For each cross-cutting module from CE-25's config, collect call sites.
2. Group by the first argument (event name / log key / telemetry path / audit category).
3. Apply string / list similarity clustering (reuse Archdo's existing Type-2/Type-3 clone detection machinery, retargeted from code shapes to event-name shapes).
4. For each cluster of size ≥ 3 with high similarity, fire on the cluster (each call site is a finding pointing to the cluster's representative name).

**Why it hurts:** consumers downstream — log aggregators, telemetry dashboards, audit pipelines, alerting rules, BI tooling — must know about all the variants. Adding a new variant breaks dashboards silently; renaming an existing variant requires coordinated change across producer code, dashboards, alerts. The cross-cutting concern has scattered without a unifying taxonomy. Changeability is impaired specifically because every change to the taxonomy is now N changes.

**Fix:** centralize the concern's taxonomy:
- For telemetry: define a `MyApp.Telemetry` module with `@event` constants or a `event_name/1` function exposing the canonical event names; route all `:telemetry.execute` calls through it.
- For logging: define structured-logging helpers per concept (`MyApp.Log.user_created/1`) that produce the canonical key set.
- For audit: define audit-event constructors that ensure consistent shape.
- The fix is one centralization PR + a follow-up to migrate call sites; CE-26 should auto-suppress on call sites that route through the centralized module.

**Exemptions:** dashboard / log-aggregator owner has signed off on the variant set — mark with `# archdo:allow CE-26 reason: ...` at the cluster's call sites; the variant is part of an external schema (audit feed consumed by another team's pipeline with its own naming convention).

**Auto-fix:** No (centralization shape is design-dependent; mechanical name unification is fragile).

---

#### CE-27 — Architectural boundary without telemetry span

**Detects:** Phoenix controller actions, public-API entry points, `Mix.Task.run/1` callbacks, `Oban.Worker.perform/1` callbacks, and channel handlers lacking a `:telemetry.span` (or framework-equivalent) wrapping the work.

**Algorithm:** identify boundary entry points reusing the anchor set from Group I; for each, scan the body and the up-to-2-levels-up call chain for `:telemetry.span`, `:telemetry.execute`, `Phoenix.LiveView.handle_event` (which emits its own telemetry), or framework-provided equivalents listed in `.archdo.exs` `telemetry_emitters`. If none reachable, fire informational.

**Why it hurts:** the boundary is invisible to operations. Latency, error rates, and throughput cannot be measured; alerting cannot be wired up; SLO tracking is impossible. CE-25 catches *too much* observability; CE-27 catches *none*.

**Fix:** wrap with `:telemetry.span([:app, :concern, :action], metadata, fn -> ... end)`. Standardize the event-name taxonomy alongside (CE-26 catches drift if not).

**Exemptions:** module / function marked `@archdo_no_telemetry reason: ...`; observability is centralized at a higher layer (configurable list of "covered-by" patterns — e.g., a Plug emitting telemetry for all routed requests).

**Auto-fix:** Can generate a `:telemetry.span` wrapper as a stub.

---

#### CE-28 — Error path without log

**Detects:** functions returning `{:error, _}` literals or containing `rescue` blocks that don't emit a log.

**Algorithm:** AST scan for `{:error, _}` literal returns and `rescue` clauses. For each, walk up the static call graph two levels checking for a `Logger.error` / `Logger.warning` call mentioning the error or the function in scope. If absent at every level reachable from the error site, fire.

**Why it hurts:** errors disappear silently; debugging requires reproducing the path; alerting cannot fire on patterns the logs don't expose.

**Fix:** add `Logger.error("...", error: e, ...)` (with structured metadata, not a string-formatted error) at the error-introduction point or the nearest catch-up boundary.

**Exemptions:** the error is normal control-flow tuple expected by the caller (e.g., `Repo.fetch` returning `{:error, :not_found}` when the caller treats that as a domain answer, not a failure); function tagged `@archdo_silent_error reason: ...`.

**Auto-fix:** No (log placement is a judgment call).

---

#### CE-29 — Process state without inspection hook

**Detects:** long-running stateful processes (`use GenServer`, `use Agent`, `:gen_statem` callback modules) whose state is opaque — no `format_status/1` callback, no documented `:sys.get_state`-friendly state shape, and the state struct (if any) has no `@derive Inspect` or custom `Inspect` impl.

**Algorithm:** identify modules using long-running stateful behaviours; check for `format_status/1` definition or a state-shape attribute exposing operational info. Modules whose state is a struct with potentially-sensitive fields (PII patterns) should *also* have an Inspect derivation that filters them.

**Why it hurts:** debugging requires tracing or restarts; runbooks become guess-and-check; production support has no live introspection. For PII-bearing state, lacking an Inspect filter risks leaking via observer / `:sys.get_state` outputs.

**Fix:** implement `format_status/1` returning a sanitized state representation; add `@derive {Inspect, except: [:secret_field, :pii_field]}` on the state struct.

**Exemptions:** state genuinely contains operational secrets and operator must run with elevated access; marker `@archdo_opaque_state reason: ...`.

**Auto-fix:** Can generate `format_status/1` stub.

---

### Group I — Justification and traceability (4 rules)

The deepest architectural question: does this code have any reason to exist at all? Pure dead-code analysis (Archdo rule 6.34, orphan modules) catches code that is unreachable from anywhere. It misses the more common LLM and over-engineering failure mode: **mutually-reachable islands of code that look fine locally but trace to nothing externally meaningful**.

The principle: every piece of code, transitively, should trace to an **anchor** — something with externally-justified existence. Reachability *from anchors* is the right notion of "this code has reason to exist." Reachability *from anywhere* (including from other unanchored code) is too permissive.

#### Anchor set

The anchor set is statically nameable and reused by every rule in this group. Defaults:

- HTTP routes — entries in modules that `use Phoenix.Router`, mapped to controller / LiveView actions
- Phoenix channels and channel topics
- Supervised processes — anything in `application.ex` `children/1` or returned from a `Supervisor.init/1` callback
- `Mix.Task` implementations
- Registered `Oban.Worker` modules
- Scheduled jobs (Oban.Cron, Quantum, custom schedulers)
- Public API modules declared in `mix.exs` `package.exports` or in `.archdo.exs` `public_api_paths`
- Application lifecycle callbacks (`Application.start/2`, `Application.prep_stop/1`)
- Released NIFs and ports
- User-extensible via `.archdo.exs` `additional_anchors` (module names or path globs)

Tests are tracked as a *separate* anchor closure — code reachable only from `test/` is reported separately as **test-only-anchored**, often legitimate (test helpers) but sometimes a smell (production module with no production caller).

#### CE-30 — Unanchored module or public function

**Detects:** a module (or specific public function) not transitively reachable from any anchor.

**Algorithm:**
1. Build the call graph + import/use graph.
2. Compute the closure of the anchor set under "calls" and "uses."
3. Any module / public function outside the closure fires.
4. Compute the test-only closure (anchored by `test/` files); modules in the test-only closure but not the production closure are reported as **test-only-anchored** at informational severity.

**Why it hurts:** the code adds maintenance load, search-result noise, refactor friction, and dependency surface without contributing to any externally-visible behaviour. This is the most common form of "unjustified code" in LLM-generated and exploratory codebases — the pattern of building scaffolding without wiring it to a route, job, or task.

**Fix:** delete the module / function, or add the missing anchor (route, supervised process, `Mix.Task`, public-API declaration) that justifies its existence.

**Exemptions:** module marked `@archdo_anchor reason: ...` (declares itself an anchor with a stated rationale, e.g., "called via :erpc from sibling node"); module is a known plugin / extension hook for downstream consumers (`@archdo_extension_point true` from the Indirection Economy markers); module is generated code (schema-derived, protocol-derived, etc.).

**Auto-fix:** No (deletion of public modules requires reviewer judgment about external consumers).

---

#### CE-31 — Unanchored island (mutually-reachable cluster)

**Detects:** a strongly-connected component (SCC) in the call graph whose members are not transitively reachable from any anchor — and not reachable from any anchored code outside the SCC.

**Algorithm:**
1. Tarjan's SCC algorithm on the call graph (modules as nodes, calls/uses as edges).
2. For each SCC of size ≥ 2, check whether any of its members is in the anchored closure. If none is, fire as a single grouped finding (not one per module — the cluster is the unit of diagnosis).
3. Report the cluster's members, the strength of mutual reference (call counts), and the absence of any external anchored caller.

**Why it hurts:** more insidious than CE-30 because every individual module looks fine locally — each has callers, each has callees, each is "used." The smell only emerges when you ask "but who uses any of you, ultimately?" Cluster size is irrelevant — a 2-module mutual reference unanchored is just as dead as a 20-module web. This is precisely the *connected but unimportant* category that pure dead-code analysis cannot detect.

**Fix:** delete the cluster, or attach an anchor. If the cluster represents a feature that was built but never wired up to a route / job / task / public API, decide whether to wire it up or remove it. Often the right answer is to delete — the cluster is leftover from exploration, a removed feature, or speculative scaffolding that never connected to the real system.

**Exemptions:** any one cluster member marked `@archdo_anchor reason: ...` declaring the public-extension or external-call rationale; the cluster is reachable via dynamic dispatch the static graph cannot resolve (`apply/3`, `Code.ensure_loaded/1`, runtime config) — Archdo's `--compiled` mode should be used to rule this out before treating the finding as actionable.

**Auto-fix:** No.

---

#### CE-32 — Public function lacks requirement annotation (opt-in)

**Detects:** public functions on traceability-required paths without an `@requirement`, `@spec_ref`, or `@trace` module attribute.

**Activation:** opt-in via `.archdo.exs` `traceability_required_paths`. Off by default; on for regulated / safety-critical / contractually-traceable codebases.

**Algorithm:**
1. For each public function in modules under `traceability_required_paths`:
   - Check for `@requirement "REQ-..."`, `@spec_ref "RFC ..."`, or `@trace ~w(REQ-... ADR-...)` immediately preceding the function definition or at module level.
2. If absent, fire.

**Why it matters:** in regulated industries (medical device software per IEC 62304, aviation per DO-178C, automotive per ISO 26262, financial controls under SOX), every line of code must trace to an approved requirement. Beyond compliance, the discipline forces deliberate intent: the act of writing the requirement reference makes "why does this code exist?" an explicit authorial decision rather than implicit accumulation.

**Annotation format:** free-form strings; the framework only checks presence. Common patterns:
- `@requirement "REQ-1234"` — single requirement
- `@requirement ["REQ-1234", "REQ-1235"]` — multiple
- `@spec_ref "RFC 7231 §6.5.1"` — external standard reference
- `@trace ~w(REQ-1234 ADR-0042)` — composite trace (requirement + ADR)

**Fix:** add the annotation. If no requirement covers the function, that is itself the finding — the function probably shouldn't exist (CE-30) or a requirement needs to be created.

**Exemptions:** function marked `@archdo_no_trace reason: ...` (rare; usually temporary scaffolding with a deletion deadline).

**Auto-fix:** Can generate annotation stubs as `@requirement "TODO"` placeholders (informational; author replaces TODO with real reference).

---

#### CE-33 — Dead requirement (opt-in, reverse traceability)

**Detects:** a requirement listed in an external requirements source with no referencing `@requirement` annotation in the code.

**Activation:** opt-in via `.archdo.exs` `requirements_source` pointing at a CSV / YAML / JSON file (or URL) exporting the requirement list from the project's tracker (Jira, Linear, requirements management tool).

**Algorithm:**
1. Parse the requirements source; collect all requirement IDs.
2. Scan all `@requirement`, `@spec_ref`, `@trace` annotations across the codebase; collect referenced IDs.
3. Set difference: requirements present in the source but absent from annotations.
4. Fire one informational finding per missing requirement, listing the requirement ID and (if available) its status / priority from the source.

**Why it matters:** closes the traceability loop. CE-32 says "every line of code traces to a requirement"; CE-33 says "every requirement traces to code." Without the reverse direction, requirements can be approved, planned, and forgotten without anyone noticing they were never implemented.

**Fix:** implement the missing requirement, mark it as deprecated / cancelled in the source tracker, or explicitly mark it as out-of-scope-for-this-codebase (`status: not_in_scope` in the source) which exempts it from CE-33.

**Exemptions:** requirement explicitly marked in the source file with a status that excludes it (configurable list of exempt statuses, e.g., `[:cancelled, :deferred, :out_of_scope]`); requirement marked in `.archdo.exs` `traceability_exempt_requirements`.

**Auto-fix:** No.

---

### Limits of static justification analysis

Three categories the framework genuinely cannot reach:

1. **"This code is technically anchored but the anchor itself is unused."** A `Mix.Task` that nobody runs, a Phoenix route handling a deprecated feature, an Oban worker scheduled but with no consumers — these all are anchors and CE-30/31 will not fire on them. Detecting unused-but-declared anchors needs runtime evidence (request logs, job execution data) the static tool doesn't have. Honest limitation; document it.
2. **"This requirement annotation is wrong / outdated."** Static can verify presence of `@requirement "REQ-123"`, not whether the code still implements REQ-123. Annotation drift is a known problem in mature codebases practicing traceability; only periodic human review catches it.
3. **"Anchored, reached, tested — but conceptually unimportant."** A feature used by 0.001% of users that consumed engineering effort disproportionate to its value isn't unjustified by any static measure. Product-judgment territory, not architecture.

---

### Group J — Resilience (5 rules)

The framework checks volatile-boundary *abstraction* (CE-1, CE-2). Group J adds volatile-boundary *failure handling*. Real production systems need timeouts, retry/breakers, supervision shape that fits the workload, bounded buffers, and explicit backpressure — all statically detectable as presence/absence at the right structural location.

#### CE-34 — Volatile call without explicit timeout

**Detects:** call sites to `:volatile` or `:non_deterministic` deps without an explicit timeout argument or option.

**Algorithm:** for each call to a tagged module, parse the argument list / opts looking for timeout-shaped keys (`:timeout`, `:recv_timeout`, `:connect_timeout`, `:request_timeout`, `:pool_timeout`, etc.) per a per-library configuration table. If the API supports a timeout and none is specified, fire. `GenServer.call/2` with no third argument falls in this set (5s default is rarely the right answer for production calls).

**Why it hurts:** default-infinite or vendor-default timeouts compound under failure — one slow downstream call stalls the calling process indefinitely, which under load propagates to mailbox saturation and then to global outage. The 5s `GenServer.call` default in particular is a frequent source of cascading failures.

**Fix:** add explicit timeout matched to SLA. For `Tesla` / `Finch` / `Req`, set `:recv_timeout`, `:connect_timeout`, and (if supported) `:pool_timeout`. For `GenServer.call`, pass the timeout as the third argument.

**Exemptions:** call is inside a `Task` with its own supervised timeout; explicitly marked.

**Auto-fix:** No (timeout value is a design decision tied to SLA).

---

#### CE-35 — Volatile boundary without retry / circuit breaker

**Detects:** modules classified `:volatile` that call external services without any retry library, exponential backoff helper, or circuit breaker visible in the call stack.

**Algorithm:** for each volatile module's outbound volatile calls, check up the call graph (caller, caller-of-caller) for retry / breaker patterns: `Retry.with_retries`, `:fuse.ask`, custom helpers (configurable via `.archdo.exs` `retry_helpers`, `breaker_helpers`). If none present and the call is to a `:volatile` dep tagged in `dependency_volatility`, fire.

**Why it hurts:** transient failures (network blips, downstream rate limits, vendor 503s) become user-visible errors; repeated failures cascade without protection. The volatility classification said "this dep will fail unpredictably" — ignoring that classification at the call site is the bug.

**Fix:** wrap calls in retry-with-backoff for transient errors; add a breaker (`Fuse`, `:fuse`) for repeated failures. Choose retry semantics per operation idempotency.

**Exemptions:** caller is itself an Oban / SQS-consumer job that the queue will retry; idempotent operation that doesn't need explicit retry; marker.

**Auto-fix:** No.

---

#### CE-36 — Fat supervisor with mixed concerns

**Detects:** supervisors with > N children (default 8) where the children span unrelated concerns by naming heuristic.

**Algorithm:** parse `children/1` or `init/1` callbacks of `Supervisor` modules. Cluster children by module-name prefix (`MyApp.HTTP.*`, `MyApp.Jobs.*`, `MyApp.Cache.*`). If ≥ 3 distinct prefixes and total children ≥ 8, fire.

**Why it hurts:** failure of one child triggers the strategy on all (`:one_for_one` is the safest but still couples observability and lifecycle); mixed concerns mean unrelated subsystems share fate decisions; restart strategy cannot fit all concerns equally well.

**Fix:** split into per-concern subtrees (`MyApp.HTTPSupervisor`, `MyApp.JobsSupervisor`) each with concern-specific strategy and child set. The application supervisor then has 3–5 concern-supervisors as children, not 30 mixed processes.

**Exemptions:** the application supervisor where mixing is structural; explicitly marked `@archdo_application_supervisor true`.

**Auto-fix:** No (refactor).

---

#### CE-37 — Unbounded queue / mailbox / ETS table

**Detects:** producer-consumer code where producers can outpace consumers without a bounded buffer.

**Algorithm:** detect:
- `:ets.new` calls without subsequent eviction discipline (no scheduled cleanup task, no LRU, no size cap referenced)
- GenServer accepting `cast/2` from many producers without a `handle_info(:check_overflow, ...)` shape or external rate limit
- `Stream.repeatedly` / `Task.async_stream` without explicit `:max_concurrency`
- `Phoenix.PubSub` subscribers that push into a process mailbox without backpressure

**Why it hurts:** memory grows without limit during traffic spikes → OOM; mailbox-overflow GenServer becomes unresponsive; ETS tables grow until eviction forces costly compaction.

**Fix:** bound the queue. Use `GenStage` / `Broadway` for backpressure. Cap ETS via periodic eviction (scheduled `:ets.match_delete` job). Set explicit `:max_concurrency` on `Task.async_stream`.

**Exemptions:** queue is provably small by domain (administrative jobs run weekly with bounded input); producer is rate-limited upstream and the limit is documented.

**Auto-fix:** No.

---

#### CE-38 — Producer-consumer without backpressure

**Detects:** stream / pipeline code that fetches from a slow producer and feeds a fast consumer (or vice versa) without windowing / chunking / `GenStage` mediation.

**Algorithm:** detect `Stream.flat_map` / `Enum.flat_map` over a producer (`Repo.stream`, paginated fetch) feeding into a downstream call (`Repo.insert_all`, external HTTP) without `Stream.chunk_every` / `Broadway` / `Flow`.

**Why it hurts:** unbounded buffering between stages; large datasets crash on memory or stall the pipeline.

**Fix:** convert to `Stream.chunk_every(n)` with batched downstream calls; or use `Broadway` for a properly-shaped pipeline with backpressure built in.

**Exemptions:** dataset bounded by domain and known small (configurable threshold); marker.

**Auto-fix:** No.

---

### Group K — Configuration discipline (4 rules)

Configuration is where deployment-time bugs hide. Four rules catch the dominant patterns: compile-time vs runtime mismatch, secrets in compiled artifacts, missing startup validation, and environment-conditional code.

#### CE-39 — `compile_env` in volatile context

**Detects:** `Application.compile_env(:app, key)` whose value is a module of `:volatile` tag, or whose key matches patterns indicating runtime-swap-worthy configuration (`*_url`, `*_endpoint`, `*_adapter`).

**Algorithm:** scan all `compile_env` call sites; for each, resolve the configured value (when statically determinable) and check its volatility classification; for keys, check against the configurable `runtime_swap_patterns` list.

**Why it hurts:** swapping a `compile_env`-bound value requires recompilation. In a Mix release this means a new build and redeploy — turning what should be a config change into a deploy event. For volatile dependencies (HTTP clients, vendor adapters) where runtime swap is the entire point, this defeats the purpose.

**Fix:** convert to `Application.get_env(:app, key)` and route through `runtime.exs` for environment overrides.

**Exemptions:** `compile_env` is intentional because the value influences macro expansion (e.g., a feature flag that gates a `defmacro`); explicitly marked.

**Auto-fix:** No.

---

#### CE-40 — Secret in `compile_env`

**Detects:** `Application.compile_env` of values whose key matches secret patterns (`*_secret`, `*_token`, `*_key`, `*_password`, `*_credential`).

**Algorithm:** AST scan; match key names against `.archdo.exs` `secret_key_patterns` list (defaults configurable).

**Why it hurts:** secrets baked into compiled `.beam` files leak through release artifacts, container images, build logs, and crash dumps. Rotation requires full rebuild and redeploy. Standard compliance requirement (SOC 2, PCI-DSS, ISO 27001) violation.

**Fix:** use `Application.get_env` (runtime config sourced from `runtime.exs`) or fetch from a secrets manager (Vault, AWS Secrets Manager, GCP Secret Manager) at runtime.

**Exemptions:** the "secret" is a public API key with no secrecy requirement (GitHub public app ID, Stripe publishable key); explicitly marked `@archdo_public_credential reason: ...`.

**Auto-fix:** No (security-sensitive; review required).

---

#### CE-41 — Critical config without startup validation

**Detects:** `Application.get_env(:app, key)` calls outside an `Application.start/2` validation phase, where `key` is on the project's critical-config list.

**Algorithm:** identify config keys flagged as critical (configurable `.archdo.exs` `critical_config_keys`, plus heuristic auto-detection: keys read by ≥ 3 modules, keys whose absence would crash the app on first request). For each, verify that `Application.start/2` (or a `start/2`-invoked validator) reads and asserts presence of the key at boot.

**Why it hurts:** missing config produces late, deep failures — sometimes hours after the app starts, often in production-only code paths, with stack traces that point to the read site rather than the missing config. Startup-time validation converts this into fast-fail at boot, where it's caught by deployment health checks.

**Fix:** add a validator in `start/2`:
```elixir
def start(_, _) do
  validate_critical_config!()
  # ...
end

defp validate_critical_config! do
  for key <- @critical_keys do
    Application.fetch_env!(:my_app, key)
  end
end
```

**Exemptions:** config has a sensible default and absence is non-critical (caught by the get_env default arg); marker.

**Auto-fix:** Can generate the validator stub.

---

#### CE-42 — Environment branching in code

**Detects:** `if Mix.env() == :prod`, `case Application.get_env(:app, :env) do :test -> ...`, or `unless Mix.env() == :dev` patterns in non-test, non-bootstrap code.

**Algorithm:** AST scan for these patterns; exclude `test/`, `config/`, `application.ex`, and modules marked `@archdo_bootstrap true`.

**Why it hurts:** environment-aware production code is its own bug factory — production behavior differs from development behavior in ways tests cannot replicate. The canonical pattern is environment-specific *config* with environment-agnostic *code*.

**Fix:** invert the dependency. Move the environment-specific branch into config:
```elixir
# config/config.exs
config :my_app, :feature_enabled, true
# config/test.exs
config :my_app, :feature_enabled, false
# code reads the config, doesn't check env
```

**Exemptions:** explicitly marked logging or telemetry differences (development-only verbosity); test seam (which should live in `test/` anyway).

**Auto-fix:** No.

---

### Group L — Concurrency / shared-state hygiene (4 rules)

Existing coverage: CE-19 (connascence of identity), CE-20 (init-then-use), Archdo's existing OTP rules. Group L closes the remaining gaps around shared-state contention, parallelism, bottlenecks, and transaction isolation.

#### CE-43 — ETS / persistent_term write contention

**Detects:** multiple modules writing to the same ETS table (or persistent_term key) without a single-writer or atomic-update discipline.

**Algorithm:** group `:ets.insert`, `:ets.delete`, `:ets.update_element`, `:persistent_term.put` call sites by table / key. If ≥ 2 distinct modules write to the same table without `:ets.update_counter` (atomic-only) or without a documented serializing process owning writes, fire.

**Why it hurts:** race conditions producing inconsistent reads; lost updates between concurrent writers. ETS's `:write_concurrency` flag *enables* concurrent writes performance-wise but does *not* guarantee atomic update semantics for non-counter operations.

**Fix:** route writes through a single owner GenServer (which serializes), use `update_counter` for atomic increments, or accept eventual consistency and document the choice with `@ets_write_concurrent reason: ...`.

**Exemptions:** explicitly designed for write-concurrency with eventually-consistent semantics; marker on the table-creating module.

**Auto-fix:** No.

---

#### CE-44 — Sequential where parallel

**Detects:** `Enum.map` / `Enum.each` / comprehensions over an external-call function (volatile-tagged) without explicit ordering dependency.

**Algorithm:** detect `Enum.map(items, fun)` where `fun` resolves to a function in a `:volatile`-tagged module. Heuristic for ordering dependency: any of `Enum.reduce`, `Enum.scan`, `Stream.transform`, accumulator threading, or comments suggesting order matters → exempt. Otherwise fire informational.

**Why it hurts:** N items × per-call latency = sequential total; trivially parallelizable to roughly the slowest single call. For HTTP-fanout patterns (fetching N records, each from a different vendor), the latency cost of sequential is often 100×.

**Fix:** `Task.async_stream(items, fun, max_concurrency: N, timeout: T, on_timeout: :kill_task)` with concurrency tuned to downstream rate limits.

**Exemptions:** order matters (next call depends on previous result); rate limit on the downstream service constrains total RPS; marker.

**Auto-fix:** Possible with conservative defaults (`max_concurrency: 5`, timeout from CE-34 setting).

---

#### CE-45 — Process bottleneck (single GenServer for high-traffic concern)

**Detects:** a named GenServer with handle_call entry points called from many distinct call sites, doing synchronous work in `handle_call` rather than dispatching async or partitioning.

**Algorithm:** for each named GenServer, count distinct calling modules. If > 20 *and* `handle_call` callbacks contain expressions that look expensive (further `GenServer.call`, HTTP, Repo, file I/O), fire.

**Why it hurts:** every call serializes through one process; the GenServer becomes the throughput ceiling for the entire concern. Common LLM-generated pattern for "service" modules.

**Fix:** partition (Registry-keyed processes per tenant / shard), use ETS for hot-read state with the GenServer only handling writes, or queue work via a worker pool (`:poolboy`, `Broadway`).

**Exemptions:** intentional serialization point (rate limiter, leader election); marker.

**Auto-fix:** No.

---

#### CE-46 — Read inside transaction without proper isolation wiring

**Detects:** a `Repo.transaction(fn -> ... end)` block that reads via functions that don't use the transaction's connection.

**Algorithm:** scan transaction blocks for `Repo.get` / `Repo.all` / `Repo.one` calls that don't pass a `repo:` opt or aren't routed through `Ecto.Multi`. If the block performs writes and reads, fire.

**Why it hurts:** depending on the database isolation level (Postgres default `READ COMMITTED`), reads may not see writes from this transaction (they will, in fact, but consumers often assume otherwise) or may see writes from concurrent transactions in unintended ways. The pattern is also fragile under `Ecto.Adapters.SQL.Sandbox` testing.

**Fix:** convert to `Ecto.Multi` so all operations share the transaction's view explicitly. `Multi.run/3` for ad-hoc reads inside the multi.

**Exemptions:** intentional read of committed-elsewhere data (e.g., reading a config row that's stable across transactions); marker.

**Auto-fix:** No.

---

### Group M — Error handling coherence (4 rules)

Elixir gives multiple error-conveyance mechanisms (ok/error tuples, exceptions, `let it crash`, `:error` atoms) and idiomatic code mixes them deliberately at the right layers. Group M catches the *unintentional* mixing — drift across functions, scattered category names, careless rescues, information loss.

#### CE-47 — Mixed return-shape within a context

**Detects:** a context module (or feature subtree) with both bang and non-bang public functions in inconsistent proportions for similar operations.

**Algorithm:** per context module, classify each public function as bang (`name!/n`) or non-bang. Group by base name (`get_user`, `get_user!`). Fire when:
- A base name has only the bang form (caller forced into rescue for normal control flow)
- A base name has only the non-bang form for an operation that has analogous bang siblings elsewhere in the same context
- Bang/non-bang ratio across the context is inconsistent without rationale (e.g., 80% non-bang and 3 stray bang functions on similar operations)

**Why it hurts:** callers don't know which style to expect; refactoring a function from one style to another silently breaks call sites that handled the other shape.

**Fix:** pick the convention. Standard Elixir idiom: `name/n` returns `{:ok, v} | {:error, reason}`; `name!/n` raises; both exist for operations where both make sense; the bang form delegates to the non-bang form.

**Exemptions:** marker.

**Auto-fix:** Can generate the missing bang or non-bang sibling as a delegating stub.

---

#### CE-48 — Error category drift

**Detects:** error atoms or structs that are clearly synonyms scattered across the codebase: `:not_found`, `:no_user`, `:user_not_found`, `:resource_missing`, `:missing` for the same conceptual failure.

**Algorithm:** apply CE-26-style clustering specifically to the error half of `{:error, _}` returns: collect atoms and struct types, cluster by similarity (string distance for atoms, conceptual mapping for structs). Flag clusters of size ≥ 3 distinct names referring to the same conceptual failure.

**Why it hurts:** consumers must pattern-match on every variant; adding a new variant breaks pattern-matching silently in consumers; the error taxonomy has no single source of truth.

**Fix:** centralize. Define an error taxonomy module (`MyApp.Errors`) with named atoms or struct types and route all callers through it. The same fix shape as CE-26.

**Exemptions:** errors are inherently distinct (`:user_not_found` vs `:order_not_found` are legitimately different categories — flag false positive); marker on the cluster.

**Auto-fix:** No.

---

#### CE-49 — Catch-all `rescue`

**Detects:** `rescue _ -> ...` or `rescue _e -> ...` without filter on exception types.

**Algorithm:** AST scan of `rescue` clauses; flag any with bare wildcard or unfilltered single-variable pattern.

**Why it hurts:** swallows specific exceptions the function shouldn't be handling — programming errors (`ArgumentError`, `KeyError`, `MatchError`) get the same treatment as legitimate runtime failures, hiding bugs that should surface immediately.

**Fix:** rescue specific exception types: `rescue e in [Ecto.NoResultsError, ...]`. If the goal is a true last-line catch (e.g., a Plug rendering 500), the function is at a process boundary — mark with `@archdo_boundary_rescue reason: ...`.

**Exemptions:** truly last-line catch in a process boundary (Plug error renderer, GenServer exit-trap); marker.

**Auto-fix:** No.

---

#### CE-50 — `:ok` return loses information

**Detects:** functions returning literal `:ok` after operations whose result the caller would plausibly need.

**Algorithm:** scan `def`s returning literal `:ok`. Check the last meaningful expression in the body — if it's an operation that returns richer information (`Repo.insert/1` returning `{:ok, %User{}}`, an HTTP call returning a response, etc.) and that information is discarded, fire.

**Why it hurts:** the caller cannot distinguish "operation succeeded with this result" from "operation succeeded with no result." Subsequent operations needing the result must re-fetch; tests cannot assert on what was created.

**Fix:** return the meaningful value: `{:ok, user}` instead of `:ok`. Where the value isn't useful, the contract should make that explicit (`:ok` documented as fire-and-forget).

**Exemptions:** the operation is genuinely fire-and-forget (cache invalidation, notification dispatch); marker.

**Auto-fix:** No.

---

### Group N — Data lifecycle and privacy (3 rules)

Archdo has a "sensitive data exposure" rule in module-quality covering common leak paths. Group N adds three structural rules: PII handling at the schema level, retention policy presence, and right-to-deletion paths (opt-in for GDPR-scoped projects).

#### CE-51 — PII field without designated handling

**Detects:** schema fields whose names match PII patterns (`email`, `phone`, `ssn`, `*_token`, `password*`, `address`, `dob`, `date_of_birth`, `national_id`, `passport*`, `tax_id`, etc.) without:
- A custom `Inspect` impl on the schema, or `@derive {Inspect, except: [...]}` excluding the PII fields
- A configured Logger filter for the field name (presence in `.archdo.exs` `logger_pii_filters`)
- An explicit field-level audit annotation marking handling

**Algorithm:** parse Ecto schemas; for each field matching the configurable PII pattern list, check the three mitigations. Fire when none are present.

**Why it hurts:** PII leaks via logs (the most common breach surface), `inspect` output in error messages and `:observer`, telemetry payloads, crash dumps, and `Repo` query logging. The default Inspect impl on schemas reveals every field.

**Fix:** add `@derive {Inspect, except: [:email, :phone]}` on the schema; configure `Logger` filters at the application level; document handling in `@moduledoc`.

**Exemptions:** the field is intentionally public (`display_name`, `username`); marker on the field via a custom attribute or in `.archdo.exs`.

**Auto-fix:** Can generate the `@derive Inspect` line.

---

#### CE-52 — Schema without retention policy

**Detects:** Ecto schemas representing user-generated data — heuristic: has `inserted_at` / `created_at`, has a user / actor reference (foreign key to a user-like table) — without one of:
- A scheduled cleanup job (Oban / Quantum / GenServer with timer) referencing the table
- A documented `@retention :forever` (or similar) annotation with rationale
- Membership in `.archdo.exs` `infinite_retention_schemas` list

**Algorithm:** identify candidate schemas via heuristic; scan all Oban worker modules, Quantum job definitions, and scheduled GenServer modules for queries against the schema's table; check for the annotation / list membership.

**Why it hurts:** unbounded data growth; under privacy law (GDPR Article 5(1)(e), CCPA §1798.105), unjustified indefinite retention is a compliance issue. Operationally, tables grow until queries slow down or storage fills up.

**Fix:** add a scheduled cleanup job (Oban worker on cron schedule) that prunes records older than the retention window; or explicitly mark `@retention :forever, reason: "audit log required for compliance"`.

**Exemptions:** marker, or schema in the configured infinite-retention list.

**Auto-fix:** Can generate an Oban worker stub for the cleanup pattern.

---

#### CE-53 — PII schema without right-to-deletion path (opt-in)

**Detects:** PII-bearing schemas (the CE-51 set) without a deletion / anonymization function exposed somewhere in the codebase.

**Activation:** opt-in via `.archdo.exs` `gdpr_scope: true`. Off by default.

**Algorithm:** for each PII schema, search for a function whose name matches `delete_for_*`, `forget_*`, `anonymize_*`, `erase_*`, or matches a configurable pattern list, that references the schema's table or struct. Fire if absent.

**Why it matters:** GDPR Article 17 (right to erasure), CCPA §1798.105 (right to delete), Brazil LGPD Article 18(VI) all require this path. Without an explicit deletion / anonymization function, compliance is impossible — each subject deletion request becomes an ad-hoc engineering task with non-uniform results.

**Fix:** implement the function, route it from the user-account-deletion flow. Anonymization is preferable when foreign-key references prevent deletion (replace name/email/phone with deterministic hashes; preserve `inserted_at` for audit).

**Exemptions:** schema is documented as out-of-scope (employee data under separate legal basis, public profile data, anonymized analytics aggregates); marker.

**Auto-fix:** No.

---

### Group O — Blackbox composition (3 rules + score)

#### Concept: the blackbox metric

A "perfect black box" is the architectural ideal of a building block. It has finite, fully-specified inputs; a known relation from inputs to outputs; outputs that are 100% confirmable for any given input; no hidden state or side channels. Functions of this kind compose cleanly because reasoning about them locally is sufficient — you never need to know what's inside, and you never need to know what's around them.

Most existing rules in this proposal touch *components* of blackbox-ability without naming the synthesis: CE-5 catches non-determinism, CE-7 finds property-test-able functions, CE-12 measures spec coverage, CE-49 flags unfiltered rescue, CE-50 catches information loss. Group O ties these together into a single per-function score and adds the rules that operate on it directly.

The metric is valuable because it answers a question with downstream consequences: *can this code be a building block?* If yes, several architectural decisions become mechanical (property-test priority, memoization safety, parallelization safety, library-extraction candidacy, distributed-computation safety, formal-verification scope). If no, the metric tells you which component breaks the abstraction so the fix is concrete.

#### The score, decomposed

Six components, each AST-derivable per function. All six must hold for the score to be high — the components combine multiplicatively, not additively, because a function that's pure but has no spec is not a building block.

| Component | Definition | AST signal |
|---|---|---|
| **Input closure** | Every input is an explicit parameter | No reads of `Application.get_env`, `:persistent_term.get`, ETS tables, `Process.get`, mutable module-level state, `self()`, `node()`, mailbox |
| **Determinism** | Same inputs → same outputs every time | No `DateTime.utc_now`, `:rand.*`, `make_ref`, `:erlang.system_time`, no message-receive, no I/O |
| **Output completeness** | The output relation is fully specified | `@spec` present and resolves to a closed type union (no `any()` / `term()`) |
| **Totality** | No legitimate input causes a runtime crash | Clauses cover the spec'd input domain; or a final catch-all returns `{:error, _}` rather than raising |
| **Side-effect freedom** | The output is the only effect | No `Logger`, `:telemetry.execute`, ETS writes, `Phoenix.PubSub.broadcast`, `send/2`, `spawn`, `Task.start`, `Repo` writes |
| **Errors as values** | Failures are returned, not raised | Error paths return `{:error, _}` or use `with`; `raise` only for programming errors, not for legitimate domain failures |

#### Algorithm

For each function `f`:

1. **Input closure** = `1.0` if zero hidden-input reads, otherwise degraded by call-site count: `max(0, 1 − 0.2 × n)` where `n` is the count of distinct hidden-input reads.
2. **Determinism** = `1.0` if zero non-deterministic primitives, otherwise `0.0`. Binary, because one `DateTime.utc_now` is enough to break the property.
3. **Output completeness** = `1.0` if `@spec` is present and resolves to a closed type union; `0.5` if `@spec` is present but uses `any()` / `term()`; `0.0` if no spec.
4. **Totality** = `1.0` if all clauses pattern-match exhaustively against the spec'd input domain *or* a final catch-all returns `{:error, _}` rather than raising; degraded for each fall-through that could `MatchError` / `FunctionClauseError` / `CaseClauseError`.
5. **Side-effect freedom** = `1.0` if zero side-effect calls, otherwise `0.0`. Binary, because logging is a side effect even when benign — you cannot cache, parallelize, or move-across-nodes a function that logs.
6. **Errors as values** = `1.0` if no `raise` in non-error-only paths; preserved when `raise` is reachable only from impossible-input branches; `0.0` if `raise` is the response to legitimate inputs.

`blackbox_score(f) = product(components)`. Aggregate per module = mean across public functions; aggregate per context = mean across modules.

#### Exposure as metric

Three new columns in `mix archdo --metrics`:

- `blackbox_score` per public function
- `blackbox_score_p50` and `blackbox_score_p95` per module
- `blackbox_class` per function: one of `building_block` (≥ 0.9), `near_block` (0.7–0.9), `mixed` (0.4–0.7), `boundary` (< 0.4)

The class column is what reviewers read first because it answers *"is this thing a building block?"* with a yes/no rather than a number.

#### Joint with volatility — where the metric becomes diagnostic

The blackbox score is meaningful only against the volatility classification (§3.1). A volatile boundary module *should* score low; a stable domain core module *should* score high. The mismatch is the diagnostic.

| Module class | Expected blackbox score | If actual differs… |
|---|---|---|
| Stable / domain core | High (≥ 0.7) | Low score: investigate. Likely missing specs, non-deterministic calls, hidden state — all fixable problems. CE-54 fires. |
| Volatile / boundary | Low (< 0.4) | High score is fine but unusual; the module is doing more abstract work than its location suggests, often a sign it should be split (CE-4-shaped). |
| Mixed | Anywhere | The mismatch *is* the signal — see CE-4. |

The joint view answers a question neither metric alone does: *do the building blocks live where they should?* Stable cores filled with non-blackbox functions are a smell; volatile boundaries containing pure functions are a refactor opportunity.

#### Downstream decisions enabled by the score

Once `blackbox_score` is computed per function, several architectural decisions that today are judgment calls become mechanical lookups:

- **Property-test priority** — `building_block` functions are the highest-ROI property-test targets. CE-7 / CE-55 produce the queue.
- **Memoization candidates** — only `building_block` functions can be safely memoized; the cache key derivation is trivial when inputs are closed.
- **Parallelization candidates** — `Task.async_stream` is safe over a `building_block` function applied to independent inputs. Directly enables the CE-44 fix.
- **Library-extraction candidates** — modules with `blackbox_score_p95 ≥ 0.9` are by definition portable. Hex package candidates without further analysis.
- **Formal verification scope** — Dialyzer success typing, exhaustive property testing, or stronger proofs all start from the building-block set.
- **Distributed-computation candidates** — `building_block` functions can run on any node without coordination concerns.

Each of these is currently a per-function design discussion. The score makes them queries against `--metrics`.

#### CE-54 — Domain function with low blackbox score

**Detects:** a public function in a `:stable`-classified module with `blackbox_score < threshold` (default `0.7`).

**Algorithm:** compute the blackbox score per algorithm above; cross-reference with the module's volatility classification; if the module is `:stable` and the function's score is below threshold, fire. The finding reports *which* component(s) failed so the fix is concrete.

**Why it hurts:** the function lives in a part of the codebase that should consist of building blocks but isn't one. Composability suffers, testability is degraded, and the implicit dependencies on hidden state make the function hard to reason about locally. Every consumer must now know what's inside.

**Fix patterns by failed component:**
- Input closure failed (reads `Application.get_env`) → move config read to caller; pass value as parameter
- Determinism failed (`DateTime.utc_now`) → inject a clock dependency at the boundary; pass `now` as a parameter
- Output completeness failed (no `@spec`) → add one; if the type is genuinely complex, narrow with `@type` aliases
- Totality failed (non-exhaustive `case`) → add total clauses or a catch-all returning `{:error, _}`
- Side-effect freedom failed (`Logger` for normal flow) → move logging to the orchestrating layer
- Errors-as-values failed (`raise` for domain errors) → return `{:error, reason}` instead

**Exemptions:** function marked `@archdo_not_blackbox reason: ...`; module marked `@archdo_volatility :volatile` overriding the heuristic; function is generated code.

**Auto-fix:** No (component fixes vary; reviewer chooses).

---

#### CE-55 — Building-block candidate untested as such

**Detects:** a function with `blackbox_score ≥ 0.9` and no StreamData property test exercising it.

**Algorithm:** for each function classified `building_block`, search `test/` for an `ExUnitProperties.property` block that calls the function. If absent, fire informational.

**Why it matters:** a function with score ≥ 0.9 already has every property property-based testing requires (purity, determinism, closed input domain, total output relation, side-effect freedom). The property test is the natural next move, not "if we have time" — the cost is low and the coverage gain is large. This is a stronger version of CE-7: not just "could be property-tested" but "every component required is in place."

**Fix:** add a property test using StreamData. Often a 5–10 line addition.

**Exemptions:** function marked `@archdo_no_property reason: ...`; the property is genuinely hard to express (rare for true building blocks).

**Auto-fix:** Can generate a property-test stub using the function's `@spec` to derive input generators.

---

#### CE-56 — Effect leak in a near-blackbox function

**Detects:** a function whose blackbox score *would* be ≥ 0.9 except for a single side-effect call (typically `Logger`, `:telemetry.execute`, or `Phoenix.PubSub.broadcast`) — usually the only thing keeping it from being a building block.

**Algorithm:** for each function whose components other than side-effect-freedom score ≥ 0.9, count side-effect calls. If exactly one or two and they're observability-only (Logger, telemetry, PubSub), fire informational.

**Why it matters:** the diagnostic is sharper than "improve this function" — it's "this one call is keeping a building block from existing." The fix is mechanical conceptually (move the effect up the call stack to the orchestrating layer) even though it's not safe to auto-fix (effect placement matters for what gets observed).

**Fix:** move the side effect to the caller. Most often: rename the inner function (`do_x/n` or `compute_x/n`) and have the existing-named function (`x/n`) become a thin orchestrator that wraps the building-block call with the effect. The inner function then scores 1.0 and is property-test-able, memoization-safe, and parallelizable.

**Exemptions:** the effect is essential to the function's contract (e.g., the function's job is *to log*); marker.

**Auto-fix:** No (effect placement is a design decision).

---

#### Honest limits

The blackbox score has three categories it cannot reach:

1. **Semantic correctness.** A function can score 1.0 and still compute the wrong answer. The metric measures *blackbox-ability* (form), not *correctness of contents* (substance). Property tests and reviews remain necessary.
2. **Compositional correctness.** Two perfectly-blackbox functions composed together can still produce a wrong system. The composition's semantics are not checked by either component's score.
3. **Implicit-state caching.** A function that memoizes via ETS is *referentially transparent* (same input → same output) but has *hidden state* that breaks input closure. The score will mark it down even though it's behaviourally a black box. This is the right call for most uses — you cannot move it across a node boundary, cannot reason about its memory locally — but the diagnostic should expose `is_memoized: true` separately so reviewers can interpret correctly.

The metric is form, not substance. It tells you what you've earned the right to do, not whether you've done it correctly.

---

## 5. False-positive mitigation

Three sources of false positives, each addressed by a specific mechanism:

### 5.1 Volatility misclassification

The kind-of-code heuristic is strong but not perfect. A module may import `Tesla` only for a single retry helper (not really volatile in spirit), or pure code may legitimately use `DateTime.utc_now/0` once for an audit timestamp.

**Mitigation:**
- Author override via `@archdo_volatility :stable | :volatile | :mixed`
- Per-call suppression for CE-5 (single non-deterministic call)
- Path-based override via `.archdo.exs` `volatile_paths` / `stable_paths`
- Classification is reported in every finding so the reviewer can validate the input

### 5.2 Legitimate Ecto / Phoenix patterns

Ecto schemas are inherently struct-shaped and constructed in many places. Phoenix controllers legitimately have I/O-density above stable thresholds. These should not produce noise.

**Mitigation:**
- Ecto schemas exempted by default from CE-8 (internal struct in return type)
- Ecto changeset construction patterns exempted from CE-9
- Phoenix controllers classified as volatile by structural rule (`use Phoenix.Controller`), so CE-5 doesn't fire on `conn` manipulation
- Patterns documented in `--explain CE-X` output

### 5.3 Test code with intentional shared state

Some test categories (integration tests, end-to-end) legitimately share state; forcing async-safety would be wrong.

**Mitigation:**
- ExUnit tag `:async_unsafe` exempts a test module from CE-6
- Path-based exemption for `test/integration/**`
- Each finding lists the exemption mechanism in the counter-case section

---

## 6. Suppression design

Identical mechanism to Indirection Economy: extended `# archdo:allow CE-X reason: ...` syntax with mandatory `reason:` clause. Per-rule severity tuning via `.archdo.exs`. Suppression count and stale suppressions tracked via `--freeze-stats`.

The reason-bearing suppressions for CE rules tend to be especially valuable as living documentation, because they capture authorial decisions like:

```elixir
@archdo_volatility :stable
# archdo:allow CE-5 reason: timestamp captured once at module load,
#   used for cache invalidation only
@compiled_at DateTime.utc_now()
```

```elixir
# archdo:allow CE-3 reason: protocol-based validation is the contract
#   for downstream library users; stable internally but extensible externally
@archdo_extension_point true
defprotocol MyApp.Validatable do ... end
```

Over time these accumulate into a per-codebase architectural commentary explaining *why* the structure is the way it is — exactly the documentation that's hardest to write retroactively.

---

## 7. The static / LLM boundary

The same two-layer model as Indirection Economy.

| Question | Static answer | LLM second-layer answer |
|---|---|---|
| Is this volatility classification correct? | Computed from imports + call density + path | `/elixir` reads `@moduledoc` and surrounding code to verify |
| Is this volatile boundary going to actually change? | Cannot tell without history | `/elixir` reads commit messages, vendor docs, ADRs |
| Is this irreversible decision really irreversible in this codebase? | Heuristic by module type | Domain knowledge — is the schema migration policy strict, is the API public-public or internal-public? |
| Is this triplicate extraction worth it? | Three instances exist | `/elixir` evaluates whether the three will diverge, stay aligned, or compound |
| Should I add a property test for this function? | Spec is pure-looking | `/elixir` evaluates whether the function has interesting properties at all |

Layer 1 produces structurally-defensible candidates. Layer 2 brings domain judgment. Both are necessary.

---

## 8. Calibration plan

Same dual-cohort approach as Indirection Economy:

### 8.1 Reference cohort

Phoenix, Ecto, Oban, Broadway, Tesla, Plug. Run all CE rules with default config. Expected outcomes:

- Volatility classification produces a clean boundary/core split
- CE-1, CE-2 fire only at unmocked external dependencies (rare in mature libs)
- CE-11, CE-12 fire near-zero (these libs document and spec their public APIs)
- CE-13 may fire moderately (large libs accumulate parallel patterns)

False-positive rate < 5% on each rule after appropriate exemption markers.

### 8.2 Smell cohort

LLM-generated CRUD apps; tutorial Phoenix apps; over-architected internal projects.

Expected outcomes:

- High CE-3 fire rate (Substitutability paid for in stable cores that don't need it)
- Moderate CE-1 / CE-2 (volatile boundaries written without test seams or insulation)
- High CE-5, CE-6 (testability hazards)
- High CE-8 / CE-9 (broken information hiding)
- High CE-12 (low spec coverage)

### 8.3 Differential signal

Same `(smell − reference)` gap test. Aim for ≥ 5× discrimination per rule.

### 8.4 Comparative scoring as a first-class output

Beyond calibration, the comparative method should be a runtime feature:

```bash
mix archdo --compare-with phoenix,ecto,oban
```

Runs CE rules on the project and on the named reference codebases (cached locally), produces a side-by-side report of normalized scores. Outliers in either direction are findings. This replaces the missing time-axis trend with a peer-axis comparison.

---

## 9. Output and integration

### 9.1 Finding format

Each CE finding includes the same structure as IE findings, with one addition: the **volatility classification of the affected module** is always reported, since most CE rules depend on it.

```
CE-1 Volatile module with hardcoded dependency
  lib/acme/billing/stripe_client.ex:34
  Module: Acme.Billing.StripeClient (volatility: volatile)
  Call: Tesla.get(client, "/charges/" <> id)
  Diagnosis: External HTTP call has no behaviour seam, no Mox port,
             no injected dependency.
  Fix: Define Acme.Billing.HTTPAdapter behaviour, route through it,
       add Mox.defmock(HTTPAdapterMock, for: Acme.Billing.HTTPAdapter)
       in test_helper.exs.
  Could be intentional if:
    - This is exercised only by integration tests with real Stripe sandbox:
      add `# archdo:allow CE-1 reason: real Stripe sandbox in test env`
    - The module is deliberately unmocked at this layer:
      add `@archdo_no_seam reason: ...`
  Volatility input: volatile_density=0.62 (Tesla, Jason, Stripe SDK calls);
                    no @archdo_volatility override; not in stable_paths.
```

### 9.2 Aggregate metric

A new column in `mix archdo --metrics`: **Change Economy score** per module and project-wide. Computed as the geometric mean of five normalized sub-scores:

| Sub-score | Definition |
|---|---|
| **Purity at core** | pure-function ratio across stable modules |
| **Mockability at boundary** | `1 − (CE-1 finding count / volatile module count)` |
| **Information hiding** | `1 − (CE-8 + CE-9 finding count / public function count)` |
| **Contract density** | `@spec` coverage on public API modules (CE-11/12) |
| **Substitutability placement** | Pearson correlation between `volatility_classification` and `abstraction_density` (Substitutability density), mapped to [0,1]. High = Substitutability concentrates at volatile boundaries, not in stable cores. |

Higher = leaner. Compare to reference cohort to interpret absolute values.

### 9.3 SARIF and HTML

Same as IE pack: SARIF rule URIs, HTML grouped section. The HTML report should additionally render a **volatility map** — a treemap or heatmap of modules colored by classification, with CE finding density overlaid. This single visualization answers "where is the codebase fragile?" at a glance.

### 9.4 MCP tool surface

Three new tools:

- `archdo_change_audit(paths)` — runs only CE rules
- `archdo_volatility_map(paths)` — returns the per-module volatility classification + abstraction density, suitable for LLM Layer 2 to consume
- `archdo_balance_check(paths)` — runs IE + CE together and produces the combined balance score, including the volatility / Substitutability match

---

## 10. Implementation roadmap

Six phases, each independently shippable.

### Phase 1 — Volatility classifier (1–2 weeks)

The foundation. Most other rules depend on it.

- Implement the volatility-primitives import scan
- Implement the path-based override config
- Implement `@archdo_volatility` module attribute
- Surface classification in `--metrics`
- Calibrate volatile/stable thresholds against the reference cohort

### Phase 2 — Group A volatility-match rules (1–2 weeks)

- Implement CE-1, CE-2, CE-3, CE-4
- Reuse Mox-detection from Indirection Economy pack
- Calibrate: reference cohort should fire low-to-moderate on CE-2, near-zero on CE-3

### Phase 3 — Group B testability rules (1 week)

- Implement CE-5, CE-6, CE-7
- Wire informational-level severity for CE-7 (testing investment opportunities, not problems)

### Phase 4 — Group C information hiding rules (1 week)

- Implement CE-8, CE-9, CE-10
- Add Ecto-pattern exemptions
- Auto-fix for CE-9 when constructor exists

### Phase 5 — Group D contract rules (1 week)

- Implement CE-11, CE-12
- Reuse `@spec` parsing across rules
- Generate `@spec` stubs from Dialyzer where possible (informational)

### Phase 6 — Extraction + comparative scoring (1–2 weeks)

- Promote clone detection to CE-13
- Implement `--compare-with <codebases>` mode
- Build the volatility-map HTML visualization
- Add the three new MCP tools

---

## 11. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Volatility heuristic mis-classifies modules, cascading false positives in Group A | Author override attribute; path overrides; classification visible in every finding |
| Phoenix codebases produce noise because controllers are structurally volatile | Phoenix-aware exemptions; controller bodies typically benign; calibrate thresholds with Phoenix in reference cohort |
| Ecto schemas trip CE-8, CE-9 by design | Ecto-aware default exemptions baked in |
| Property-test-ability (CE-7) fires on hundreds of pure functions, drowns reviewer | Default severity informational; introduce only when reviewer requests with `--rule-severity CE-7=warning` |
| CE-11 punishes early-stage projects without complete docs/specs | Default thresholds keyed to codebase median, not absolute; prototype-mode flag (`--mode prototype`) relaxes contract rules |
| Reviewers interpret CE-3 as "all flexibility is bad" and over-simplify volatile boundaries | §1.1 makes the Changeability vs Substitutability distinction explicit; counter-case list in every finding; cross-reference to CE-2 (where Substitutability earns its keep); volatility classification visible alongside |
| Reviewers interpret CE-2 as "always add a behaviour" and over-abstract simple internal helpers | CE-2 fires only on volatile modules with ≥ 2 non-volatile callers; single-caller helpers are exempt; Substitutability is recommended only where it converts a real testability/insulation problem into an easy one |
| The `--compare-with` mode requires fetching reference codebases, may be slow | Cache reference scan results; ship a precomputed "reference baseline" data file with releases |

---

## 12. Why this matters

Indirection Economy answers the question "is this Substitutability investment earning its keep?" Change Economy answers two inverses:

- "Is Substitutability missing exactly where the volatile context demands it (test seam, insulation)?"
- "Are there structural impediments to Changeability anywhere in the codebase (broken information hiding, missing contracts, testability hazards, careless commitment to irreversible decisions)?"

The questions are independent in a precise way. A codebase can be perfectly free of unjustified Substitutability investments and still:

- Have hardcoded HTTP calls in volatile modules (no seam where one is needed — CE-1)
- Leak internal structs across module boundaries (information hiding broken, Changeability impeded — CE-8)
- Have non-deterministic calls in domain code (testability undermined — CE-5)
- Lack contract density at irreversible decision sites (carelessness where it costs most — CE-11)

Conversely, a codebase can score perfectly on Change Economy by adding Substitutability layers everywhere — at which point Indirection Economy fires. The two packs together form a closed loop:

- IE forces every Substitutability investment to justify itself.
- CE forces Substitutability to appear where the volatile context earns it, *and* forces Changeability impediments to be removed throughout — independent of the Substitutability question.

The static, history-free formulation means both are usable on day one of a new project, not just after a year of churn data has accumulated. This matters especially for projects where:

- The codebase is fresh (greenfield, recently extracted, or rewritten)
- Git history is absent or rewritten (squashed migrations, monorepo extraction)
- The reviewer wants a one-shot architectural assessment without setting up history-aware tooling

For LLM-generated codebases — Sonnet, GPT, Gemini, etc. — both packs are particularly load-bearing. Generated code is typically over-abstracted in pure-domain regions and under-protected at I/O boundaries, the exact pattern these rules detect.

---

## 13. Open questions for the maintainer

1. **Volatility classifier as a separate module?** The classifier is foundational and reusable. Should it be exposed as its own Mix task / MCP tool (`mix archdo.volatility`) for projects to consume independently of the rule pack?
2. **Default severity for testability rules.** CE-5, CE-6, CE-7 differ in urgency. Recommendation: CE-5 warning, CE-6 warning, CE-7 informational by default. Tunable per project.
3. **Reference cohort selection for `--compare-with`.** Should there be a curated default set per project archetype (Phoenix web app, library, OTP application, Nerves firmware)? The classifier could detect archetype from `mix.exs` deps.
4. **Interaction with the Indirection Economy pack.** A CE-2 finding (volatile boundary lacks abstraction) suggests adding a behaviour, which IE-1 might then flag if the behaviour starts with one impl. The two packs need cross-references in their messages: CE-2 should suggest a Mox-paired behaviour, and IE-1 should auto-suppress when the parent finding is CE-2.
5. **Comparative scoring privacy.** Running `--compare-with` against private reference codebases (a company's internal "good" exemplar) is valuable. Should the cache support pinning to a commit, hashing for distribution, or remain purely local?

---

## Appendix A — Quick reference table

| Rule | Group | Pattern | Auto-fix |
|---|---|---|---|
| CE-1 | A | Volatile module with hardcoded volatile call | No |
| CE-2 | A | Volatile boundary lacks abstraction | No |
| CE-3 | A | Stable core with high abstraction density | No |
| CE-4 | A | Mixed-volatility module (split candidate) | No |
| CE-5 | B | Non-deterministic call in stable module | No |
| CE-6 | B | Test isolation hazard | Some |
| CE-7 | B | Property-test-able function lacks property test | Stub gen |
| CE-23 | B | High cognitive complexity public function | No |
| CE-24 | B | Cyclomatic / cognitive complexity shape mismatch | No |
| CE-8 | C | Internal struct in public return type | No |
| CE-9 | C | Cross-module struct construction | When constructor exists |
| CE-10 | C | Excessive public API surface | No |
| CE-11 | D | Irreversible decision lacks contract density | No |
| CE-12 | D | Public API module with low spec coverage | Stub gen |
| CE-13 | E | Triplicate code shape | No |
| CE-14 | F | External-facing data shape lacks versioning | No |
| CE-15 | F | Wrapper layer over framework-provided abstraction | No |
| CE-16 | F | Ecto schema with significant domain behavior | No |
| CE-17 | G | Connascence of meaning across modules | No |
| CE-18 | G | Connascence of position with high arity | No |
| CE-19 | G | Connascence of identity via implicit naming | No |
| CE-20 | G | Init-then-use without supervision dependency | No |
| CE-21 | G | Acquire/release pair without bracket helper | Stub gen |
| CE-22 | G | Multi-call protocol on a single process | No |
| CE-25 | H | Cross-cutting concern density per function | No |
| CE-26 | H | Scattered cross-cutting concern | No |
| CE-27 | H | Architectural boundary without telemetry span | Stub gen |
| CE-28 | H | Error path without log | No |
| CE-29 | H | Process state without inspection hook | Stub gen |
| CE-30 | I | Unanchored module or public function | No |
| CE-31 | I | Unanchored island (mutually-reachable cluster) | No |
| CE-32 | I | Public function lacks requirement annotation (opt-in) | Stub gen |
| CE-33 | I | Dead requirement (opt-in, reverse) | No |
| CE-34 | J | Volatile call without explicit timeout | No |
| CE-35 | J | Volatile boundary without retry / circuit breaker | No |
| CE-36 | J | Fat supervisor with mixed concerns | No |
| CE-37 | J | Unbounded queue / mailbox / ETS table | No |
| CE-38 | J | Producer-consumer without backpressure | No |
| CE-39 | K | `compile_env` in volatile context | No |
| CE-40 | K | Secret in `compile_env` | No |
| CE-41 | K | Critical config without startup validation | Stub gen |
| CE-42 | K | Environment branching in code | No |
| CE-43 | L | ETS / persistent_term write contention | No |
| CE-44 | L | Sequential where parallel | Conservative |
| CE-45 | L | Process bottleneck (single GenServer for high-traffic) | No |
| CE-46 | L | Read inside transaction without isolation wiring | No |
| CE-47 | M | Mixed return-shape within a context | Stub gen |
| CE-48 | M | Error category drift | No |
| CE-49 | M | Catch-all `rescue` | No |
| CE-50 | M | `:ok` return loses information | No |
| CE-51 | N | PII field without designated handling | Stub gen |
| CE-52 | N | Schema without retention policy | Stub gen |
| CE-53 | N | PII schema without right-to-deletion path (opt-in) | No |
| CE-54 | O | Domain function with low blackbox score | No |
| CE-55 | O | Building-block candidate untested as such | Stub gen |
| CE-56 | O | Effect leak in a near-blackbox function | No |

---

## Appendix B — example `.archdo.exs` additions

```elixir
%{
  # Per-dependency volatility profile (replaces the flat volatile_modules list).
  # Tags: :stable | :stable_with_test_seam | :volatile | :non_deterministic
  dependency_volatility: [
    # Stable — narrow surface or standards-implementing library at maturity.
    # The rationale string surfaces in findings.

    # Stdlib & BEAM (intrinsically stable)
    {:lists, :stable, "OTP stdlib"},
    {:maps, :stable, "OTP stdlib"},
    {:erlang, :stable, "BEAM primitives"},
    {:string, :stable, "OTP stdlib"},
    {Phoenix.PubSub, :stable, "framework primitive"},

    # Standards-implementing libraries (mature)
    {URI, :stable, "RFC 3986"},
    {Base, :stable, "RFC 4648"},
    {:base64, :stable, "RFC 4648"},
    {:crypto, :stable, "NIST FIPS / IETF — standard algorithms"},
    {:zlib, :stable, "RFC 1950/1951"},
    {:public_key, :stable, "X.509 / PKCS"},
    {Jason, :stable, "RFC 8259 (JSON), mature lib"},
    {Decimal, :stable, "IEEE 754, mature lib"},
    {Calendar.ISO, :stable, "ISO 8601"},

    # Stable with framework-provided test seam (Group F territory)
    {Ecto.Repo, :stable_with_test_seam, "Ecto.Adapters.SQL.Sandbox"},
    {Oban, :stable_with_test_seam, "Oban.Testing"},

    # Volatile — vendor or protocol drift
    {Tesla, :volatile, "HTTP middleware ecosystem churn"},
    {Finch, :volatile, "HTTP client"},
    {Req, :volatile, "HTTP client"},
    {HTTPoison, :volatile, "HTTP client"},
    {Plug.Conn, :volatile, "Phoenix surface"},
    {~r/_sdk$/, :volatile, "vendor SDKs"},
    {~r/^ex_aws/, :volatile, "AWS API drift"},

    # Non-deterministic — testability concerns (CE-5)
    {File, :non_deterministic, "filesystem"},
    {System, :non_deterministic, "OS coupling"},
    {{:rand, :_}, :non_deterministic, "randomness"},
    {{:erlang, :system_time}, :non_deterministic, "time"}
  ],
  dependency_volatility_strategy: :metadata_aware,  # or :static_only

  # Dual-purpose modules: stable for data-shape ops, non_deterministic for
  # execution/clock/socket ops. Resolved at call-site granularity.
  dual_purpose_modules: [
    {DateTime, %{
      stable_funs: [
        {:from_iso8601, 1}, {:from_iso8601, 2},
        {:to_iso8601, 1}, {:to_iso8601, 2},
        {:to_string, 1}, {:compare, 2}
      ],
      non_deterministic_funs: [{:utc_now, 0}, {:now, 1}]
    }},
    {:inet, %{
      stable_funs: [
        {:parse_address, 1}, {:ntoa, 1},
        {:parse_ipv4_address, 1}, {:parse_ipv6_address, 1}
      ],
      non_deterministic_funs: [
        {:getaddr, 2}, {:gethostbyname, 1}
      ]
    }},
    {:calendar, %{
      stable_funs: [{:date_to_gregorian_days, 1}, {:gregorian_days_to_date, 1}],
      non_deterministic_funs: [{:local_time, 0}, {:universal_time, 0}]
    }}
  ],

  volatile_paths: [
    "lib/myapp/integrations/**",
    "lib/myapp/external/**"
  ],
  stable_paths: [
    "lib/myapp/domain/**",
    "lib/myapp/core/**"
  ],

  # Public API designation
  public_api_paths: [
    "lib/myapp.ex",
    "lib/myapp/api/**"
  ],

  # Framework-provided abstractions (Group F): Substitutability already
  # provided by the framework. Wrapping these in a project-defined behaviour
  # fires CE-15 and exempts callers from CE-2.
  framework_provided_abstractions: [
    {Ecto.Repo, "Ecto.Adapters.SQL.Sandbox"},
    {Phoenix.PubSub, "Phoenix.PubSub testing helpers"},
    {Oban, "Oban.Testing"},
    {Task, "start_supervised + Task.async/await"},
    {GenServer, "start_supervised + direct call testing"}
  ],

  # CE-16 threshold for schema-as-domain-entity drift
  domain_logic_threshold: 3,

  # Per-rule severity
  rule_severity: %{
    "CE-1" => :warning,
    "CE-3" => :warning,
    "CE-5" => :warning,
    "CE-7" => :info,
    "CE-11" => :warning,
    "CE-13" => :info,
    "CE-14" => :info,
    "CE-15" => :warning,
    "CE-16" => :warning,
    "CE-17" => :warning,
    "CE-18" => :warning,
    "CE-19" => :warning,
    "CE-20" => :warning,
    "CE-21" => :info,
    "CE-22" => :warning,
    "CE-23" => :warning,
    "CE-24" => :info,
    "CE-25" => :warning,
    "CE-26" => :warning,
    "CE-27" => :info,
    "CE-28" => :warning,
    "CE-29" => :info,
    "CE-30" => :warning,
    "CE-31" => :warning,
    "CE-32" => :off,    # opt-in via traceability_required_paths
    "CE-33" => :off,    # opt-in via requirements_source
    "CE-34" => :warning,
    "CE-35" => :warning,
    "CE-36" => :info,
    "CE-37" => :warning,
    "CE-38" => :info,
    "CE-39" => :warning,
    "CE-40" => :error,  # security
    "CE-41" => :warning,
    "CE-42" => :warning,
    "CE-43" => :warning,
    "CE-44" => :info,
    "CE-45" => :warning,
    "CE-46" => :warning,
    "CE-47" => :info,
    "CE-48" => :warning,
    "CE-49" => :warning,
    "CE-50" => :info,
    "CE-51" => :warning,
    "CE-52" => :info,
    "CE-53" => :off,    # opt-in via gdpr_scope: true
    "CE-54" => :warning,
    "CE-55" => :info,
    "CE-56" => :info
  },

  # Group O — Blackbox composition thresholds
  blackbox_threshold_warning: 0.7,    # below this in stable modules → CE-54
  blackbox_threshold_building_block: 0.9,  # at or above this → CE-55 / CE-56 territory

  # Group I — Justification & traceability
  additional_anchors: [
    # Module names or path globs treated as anchors beyond defaults
    # MyApp.ExternalAPI,
    # "lib/myapp/jobs/**"
  ],
  traceability_required_paths: [
    # Activates CE-32. Uncomment for regulated codebases.
    # "lib/myapp/safety/**"
  ],
  requirements_source: nil,
  # e.g. "priv/requirements.csv" — activates CE-33
  traceability_exempt_statuses: [:cancelled, :deferred, :out_of_scope],

  # Ecto / Phoenix exemptions (defaults; override here)
  pattern_exemptions: %{
    "CE-8" => [{:use, Ecto.Schema}],
    "CE-9" => [{:inside_changeset, true}]
  },

  # Comparative reference cohort
  compare_with: [:phoenix, :ecto, :oban, :broadway],

  # Suppression policy
  require_suppression_reason: ["CE-*", "IE-*"]
}
```

---

## Appendix C — sample suppressions in real code

```elixir
defmodule Acme.Billing.StripeClient do
  @archdo_volatility :volatile
  @moduledoc """
  Stripe HTTP client. All external calls go through Acme.Billing.HTTPAdapter
  (see CE-1, CE-2 — abstraction earned by volatility presumption).
  """

  @behaviour Acme.Billing.HTTPAdapter
  # archdo:allow IE-1 reason: volatile boundary, see CE-2;
  #   Mox.defmock for HTTPAdapter exists in test_helper.exs

  @impl true
  def get(path), do: ...
end
```

```elixir
defmodule Acme.Domain.Pricing do
  @archdo_volatility :stable

  # archdo:allow CE-5 reason: deterministic seed for hash function;
  #   tests inject a fixed seed via Application.put_env in setup
  defp seed, do: Application.get_env(:acme, :pricing_seed, :erlang.system_time())
end
```

```elixir
defmodule Acme.Public.UserAPI do
  # archdo:allow CE-12 reason: spec stubs generated, expert review pending;
  #   target completion 2026-Q3
  @moduledoc "Public user API for downstream consumers."

  ...
end
```

---

## Appendix D — State-machine rule improvements

Archdo's existing state-machine category contains three rules: *unreachable states*, *terminal state integrity*, *implicit boolean state*. They cover state reachability and one slice of legality but leave gaps in transition legality and illegal-state-unreachability — exactly the questions a reviewer would ask of any state machine. Six new rules close those gaps; three adjacent rules sharpen the existing coverage. All are static, deterministic, and target classes of bugs that Elixir's pattern-matching tends to hide until production load.

These extend the existing Archdo state-machine category rather than forming their own group (small enough to fold in; thematically aligned).

### Coverage map

| Concern | Existing | Proposed |
|---|---|---|
| All declared states reachable from initial | Unreachable states (existing) | SM-G — sharper graph reachability |
| Transitions limited to legal targets | partial (terminal integrity) | SM-A, SM-B, SM-C |
| Illegal / undeclared states not reachable | partial | SM-D, SM-E, SM-F |
| Mixed / competing state representations | Implicit boolean state (existing) | SM-H — generalized to detect competition |
| Per-transition test coverage | — | SM-I |

### Transition legality

#### SM-A — Undeclared target state in transition

**Detects:** a `gen_statem` callback (or hand-rolled state machine) returns `{:next_state, X, ...}` where `X` is not in the declared state set.

**Algorithm:**
- For state-functions-mode `gen_statem`: declared states are the names of callback functions matching the state-callback shape.
- For handle-event-function-mode: declared states are the union of `@type state` (if present) or the union of states appearing as the second element of `{:next_state, _, _}` returns combined with the initial state.
- For hand-rolled (`use GenServer` with `state` field): declared states are values in `@type state` or `@states [...]` attributes.
- For each `{:next_state, X, ...}` return, verify `X` is in the declared set. If not, fire on the return site.

**Why it hurts:** an undeclared `:next_state` target is a guaranteed runtime crash — the state machine will receive an event it has no callback for. Pattern-matching makes this invisible at compile time in handle-event-function mode and in hand-rolled machines.

**Fix:** correct the typo, or declare the missing state explicitly.

**Auto-fix:** No.

---

#### SM-B — Transition violates declared transition table

**Detects:** when the state machine declares a transition table (an `@transitions` attribute, a `transitions/0` function returning `[{from, event, to}]`, or AshStateMachine declarations), a `{:next_state, to, ...}` return that has no matching `(from, event)` entry in the table.

**Algorithm:** parse the transition table; for each callback returning a next-state, verify the `(current_state, event_pattern, target_state)` triple exists in the table.

**Why it hurts:** the transition table is the spec. When the code drifts from the spec — usually after a feature addition where the table was forgotten — every consumer (UI, telemetry, audit) that depends on the spec is silently wrong.

**Activation:** opt-in. Fires only when a transition table is declared. AshStateMachine projects get this for free.

**Fix:** add the missing transition to the table, or correct the next-state return.

**Auto-fix:** No.

---

#### SM-C — Event silently dropped in state

**Detects:** a state callback that doesn't pattern-match on a given event, where other states do match it, and there is no explicit `:keep_state_and_data` / `:postpone` / catch-all handler.

**Algorithm:** for each state, collect handled event patterns. Compute the union of all events handled across states. For each state, list events in the union but not handled in this state. Fire on asymmetric coverage (fires once per dropped event per state).

**Why it hurts:** silently dropped events are one of the hardest bugs to diagnose — the system simply doesn't respond to a stimulus, and there's no error trace pointing to the omission.

**Fix:** add a clause for the event (handle it, keep state, or explicitly postpone). If the event truly is irrelevant in this state, add an explicit `_event -> :keep_state_and_data` clause that documents the intent.

**Exemptions:** state explicitly marked as terminal (`@terminal_state true`); module-level catch-all handler exists.

**Auto-fix:** Can generate a stub `:keep_state_and_data` clause for review.

---

### Illegal-state unreachability

#### SM-D — State assignment outside declared set

**Detects:** for state-as-struct-field machines (`%MyMachine{state: :foo}`), an assignment of a state value not in the declared state list.

**Algorithm:**
1. Identify state-bearing structs (heuristic: struct has a field named `state` or `status` of type atom; or the module declares `@states [...]`).
2. Scan for assignments to that field — both struct literals and `%{m | state: X}` updates.
3. Verify each assigned atom is in the declared set.
4. Apply the same check to `gen_statem` `init/1` returns and any other state-introducing entry points.

**Why it hurts:** assigns a state the rest of the code doesn't know how to handle, leading to `FunctionClauseError` or silent misbehaviour the next time the state is dispatched on.

**Fix:** correct the assignment, or declare the new state.

**Auto-fix:** No (the fix could be either direction; reviewer decides).

---

#### SM-E — Computed state value (unverifiable)

**Detects:** a state assignment whose value is computed at runtime (`state: state_for(condition)` returning one of several atoms) where neither the function nor the call site provides a typespec narrowing the return type to the declared state set.

**Algorithm:** flag dynamic assignments as **unverifiable** rather than failed; the reviewer decides whether to add `@spec state_for(_) :: state()` (which converts the finding to a Dialyzer-checkable invariant) or accept the dynamic dispatch.

**Why it matters:** distinguishes genuine SM-D bugs from places where the static analyzer cannot see the constraint. Without this distinction, SM-D would either over-fire on dynamic dispatch or miss it entirely.

**Auto-fix:** Can suggest adding a `@spec` returning `state()` to the helper function.

---

#### SM-F — Pattern-match incomplete on state

**Detects:** a `case state do :a -> ...; :b -> ... end` (or equivalent multi-clause function) that is missing declared states, with no catch-all clause.

**Algorithm:** for any case / function clause set keyed on a state-typed value, compare matched patterns against the declared state set. Missing states without a catch-all fire.

**Why it hurts:** the dual of SM-D. The spec declares states the code doesn't handle, leading to `CaseClauseError` or `FunctionClauseError` when the state value is set legitimately but the consumer code is incomplete.

**Fix:** add the missing clauses, or add an explicit catch-all that documents the intentional gap.

**Auto-fix:** Can generate stub clauses for review.

---

### Reachability sharpened

#### SM-G — Declared state unreachable from initial state via the transition graph

**Detects:** a state declared and referenced as a transition target somewhere, but only by other states that are themselves unreachable from the initial state.

**Algorithm:** build the state graph from the transition table (or inferred from `:next_state` returns). Compute reachability from the initial state. Any declared state outside the reachable closure fires.

**Why it hurts:** stronger than the existing "unreachable states" check (which presumably looks at any incoming edge). A state pointed at only by other dead states is still dead — the same graph-reachability problem as CE-30 but on the state graph rather than the call graph.

**Fix:** either delete the unreachable state and its incoming edges, or add a transition that brings it into the live closure.

**Auto-fix:** No.

---

### Adjacent quality

#### SM-H — Mixed-representation state

**Detects:** a struct that has both an explicit `state` field *and* implicit-state-bearing fields — booleans (`is_active`, `confirmed?`, `published?`), nilable references that imply state (`approved_at`, `cancelled_at`), or status atoms outside the declared field — that compete with the explicit state for representing the same conceptual machine.

**Algorithm:** for state-bearing structs, scan the field list for booleans whose names suggest state (`is_*`, `*?`, `has_*`) and nilable timestamps (`*_at`, `*_on`) that mirror state names. If ≥ 2 such fields exist alongside an explicit `state` field, fire.

**Why it hurts:** generalization of the existing "implicit boolean state" rule. The two representations will eventually disagree — `state == :cancelled` while `cancelled_at == nil`, or `is_active == true` while `state == :archived`. Every code path that reads either representation must remember to check both.

**Fix:** consolidate. Either derive the booleans / timestamps from the state (`def cancelled?(m), do: m.state == :cancelled`) or eliminate the state field and represent the machine purely through field combinations (rarely better; usually the wrong direction).

**Auto-fix:** No.

---

#### SM-I — State machine without per-transition test

**Detects:** a state machine where the test suite does not exercise every declared transition.

**Algorithm:**
1. Parse the transition table (declared explicitly or inferred from `:next_state` returns).
2. For each `(from_state, event)` entry, search `test/` for a test that drives the machine into `from_state` and dispatches `event`.
3. Missing entries fire as informational findings (a coverage matrix).

**Why it matters:** state machines fail at the *transition* level, not at the *state* level. State coverage (every state visited by some test) is necessary but not sufficient — transition coverage is the real correctness signal. Without it, edge cases at unusual transitions ship to production unverified.

**Activation:** informational by default; promotable to warning in `--strict`. Findings list is a coverage matrix the reviewer can prioritize.

**Auto-fix:** Can generate test stubs for missing transitions (with TODO bodies).

---

### Honest limit

Static analysis catches structural transition-table violations and incomplete pattern matches. It cannot answer:

- *Is the state machine modeling the right thing?* (domain-fit)
- *Are guard expressions on transitions logically correct?* (semantic correctness on real data)
- *Does the machine match the protocol it claims to implement?* (e.g., does an OAuth flow conform to RFC 6749?)

These need property-based testing (StreamData generating event sequences with invariant assertions) or formal verification (model checking via TLA+, Alloy, or SPIN). The static rules above ensure the *implementation* matches its *declaration*; they do not ensure the declaration matches reality.

### Recommendation

Add SM-A through SM-I to Archdo's existing state-machines category. They are uniformly high-signal, low-false-positive, and target a class of bugs Elixir's pattern-matching tends to hide. SM-A, SM-D, SM-F have the highest immediate value (each catches a runtime-crash class). SM-B and SM-G require an explicit transition table to fire usefully — opt-in for projects that maintain one. SM-I is informational and produces a coverage matrix rather than defects.

---

*End of proposal.*
