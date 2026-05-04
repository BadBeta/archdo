# Archdo — Comprehensive User Guide

> **Audience.** This guide is written to be useful for both humans and LLM agents (Claude Code, Cursor, Cline, Zed, Codex). LLMs reading it as context should treat the rule descriptions, diagnostic schema, and tool contracts as authoritative.

---

## Table of contents

1. [What Archdo is and why](#1-what-archdo-is-and-why)
2. [Installation](#2-installation)
3. [The rules at a glance](#3-the-rules-at-a-glance)
   - [3.1 Precision improvements (May 2026)](#31-precision-improvements-may-2026)
     - [3.1.1 Rule 1.6 — Cross-cutting in domain](#311-rule-16--cross-cutting-in-domain-phoenix-aware-layer-detection)
     - [3.1.2 Rule 1.9 — Time injection](#312-rule-19--time-injection-default-arg-exemption)
     - [3.1.3 Rule 3.1 — Duplicated code](#313-rule-31--duplicated-code-umbrella-sibling-downgrade)
     - [3.1.4 Rule CE-11 — Contract density](#314-rule-ce-11--contract-density-test_density-sub-score)
     - [3.1.5 Rule CE-50 — :ok loses info](#315-rule-ce-50--ok-loses-info-transitively-threaded-detection)
     - [3.1.6 Rule CE-57 — Unguarded building block](#316-rule-ce-57--unguarded-building-block-module-verdict-propagation)
     - [3.1.7 Graph extraction enhancements](#317-graph-extraction-enhancements-broaden-ce-30--ce-31)
   - [3.2 Per-module suppression markers](#32-per-module-suppression-markers)
     - [3.2.1 Marker mechanics](#321-marker-mechanics)
     - [3.2.2–20 — One subsection per marker](#322-archdo_anchor--ce-30--ce-31)
   - [3.3 Change Economy rules + packs](#33-change-economy-rules--packs)
     - [3.3.1 Selected CE rules — worked examples](#331-selected-ce-rules--worked-examples)
   - [3.4 Architectural primitives](#34-architectural-primitives--the-shared-modules-behind-the-rules)
     - [3.4.1 `Archdo.Phoenix`](#341-archdophoenix--file-layer-classifier)
     - [3.4.2 `Archdo.Volatility`](#342-archdovolatility--dependency-stability-classifier)
     - [3.4.3 `Archdo.Blackbox`](#343-archdoblackbox--composability-scorer)
     - [3.4.4 `Archdo.AnchorSet`](#344-archdoanchorset--reachability-anchor-discovery)
     - [3.4.5 `Archdo.InputGuard`](#345-archdoinputguard--clause-constraint-analyzer)
     - [3.4.6 `Archdo.IrreversibleDecision`](#346-archdoirreversibledecision--schemasupervisorpublic-api-classifier)
     - [3.4.7 `Archdo.PiiSchema`](#347-archdopiischema--pii-field-detection)
     - [3.4.8 `Archdo.Graph` and `Archdo.Compiled.Graph`](#348-archdograph-and-archdocompiledgraph--dependency-graphs)
     - [3.4.9 `Archdo.Quadrant`](#349-archdoquadrant--2-axis-policy-primitive-two-dimensional-architectural-tests)
4. [The diagnostic shape](#4-the-diagnostic-shape)
5. [Output formats](#5-output-formats)
6. [CLI reference](#6-cli-reference)
7. [Configuration (`.archdo.exs`)](#7-configuration-archdoexs)
   - [Configurable thresholds](#configurable-thresholds)
8. [Freeze / baseline workflow](#8-freeze--baseline-workflow)
9. [MCP server (for LLM clients)](#9-mcp-server-for-llm-clients)
10. [Architecture (how Archdo works internally)](#10-architecture-how-archdo-works-internally)
11. [Guidance for LLM clients](#11-guidance-for-llm-clients)
11.5. [Testing Archdo itself](#115-testing-archdo-itself)
12. [Troubleshooting](#12-troubleshooting)
13. [Where to read next](#13-where-to-read-next)

---

## 1. What Archdo is and why

Archdo is an **architectural quality checker for Elixir** projects. It checks the kinds of decisions that determine whether a codebase ages well — boundaries, OTP discipline, test architecture, code duplication, NIF safety — that fall outside the scope of Credo, Dialyzer, and Sobelow:

| Tool         | Checks                                  | Doesn't check                              |
|--------------|-----------------------------------------|---------------------------------------------|
| **Credo**    | Style, naming, complexity per file      | Cross-module dependencies, OTP patterns     |
| **Dialyzer** | Type contracts                          | Architecture, design                        |
| **Sobelow**  | Phoenix security (XSS, SQLi)            | Anything not security                       |
| **Archdo**   | Boundaries, OTP, test architecture, duplication, performance traps, LLM slop, event sourcing, NIF discipline, compiled analysis, Martin metrics | Style, types, security |

Archdo is **deterministic** — same code produces the same diagnostics — so it's safe to wire into CI. It's also **self-explanatory**: every diagnostic ships with an explanation of *why* the finding matters and one or more **actionable fix options**, written so an LLM can apply them without re-reading the rule documentation.

### Design principles

1. **Convention with declaration override.** Phoenix layouts work with zero config. Non-Phoenix or unusual layouts can declare layers in `.archdo.exs`.
2. **Every diagnostic is actionable.** Every finding has a `title`, a `why`, ranked `alternatives` for fixing it, and a link back to the canonical rule documentation.
3. **Tolerate grey areas.** Architectural rules have exceptions. Most info-severity rules include "verify this is real" as the first fix option, and the freeze/baseline mechanism lets you accept pre-existing violations.
4. **No magic, no inference.** If Archdo can't classify a module from convention or declaration, it reports it as `:unknown` rather than guessing.

---

## 2. Installation

Add Archdo to your project's `mix.exs`:

```elixir
def deps do
  [
    {:archdo, "~> 0.1.0", only: [:dev, :test], runtime: false}
  ]
end
```

Then:

```bash
mix deps.get
mix archdo --help     # confirm install
```

Archdo needs `Jason` (JSON encoding) and `JSV` (JSON Schema validation for MCP tool inputs) at runtime. It does not start an OTP application, does not modify your supervision tree, and does not depend on Phoenix or Ecto — those are detected if present.

### Supported environments

- Elixir 1.15+ (developed against 1.18, 1.17 supported)
- OTP 25+
- Phoenix and non-Phoenix projects
- Umbrella projects (run from each child app's root)

---

## 3. The rules at a glance

Archdo ships rules in two complementary layers:

- **Core rules (226 rules in 11 categories)** — the original architecture-quality checks documented in [ARCHITECTURE_RULES.md](ARCHITECTURE_RULES.md). Always-on by default.
- **Change Economy rules (32 rules across 4 opt-in packs)** — a second-generation rule family focused on the *cost of changing* the system rather than its current shape. The `core` pack ships on by default; the `ce_compliance`, `ce_privacy`, and `ce_composability` packs are opt-in via `--packs`.

See §3.3 below for the Change Economy + pack system.

| #   | Category                         | Rules    | Severity mix          | What it catches                                                                  |
|-----|----------------------------------|----------|-----------------------|----------------------------------------------------------------------------------|
| 1   | Boundaries & Architecture        | 29       | error / warning / info | Dependency direction, context encapsulation, circular deps, Repo in interface, schema ownership, chatty boundaries, anemic contexts, unvalidated params, reverse dependencies, **query building in interface**, **cross-context schema access**, **direct process call across boundary**, **shared DB table**, **shared ETS table**, **cross-context config**, LiveView logic, **compiled**: compile dependency hotspot, circular function calls, change blast radius, cross-boundary call detection, Repo bypass, circular context deps, orphan modules |
| 2   | Public API                       | 2        | warning / info        | Missing `@moduledoc`, missing `@spec` |
| 3   | Single Source of Truth           | 5        | warning / info        | Type-2 clones, scattered config, library config via `Application.get_env`, Type-3 similar code, reinvented enumerable, duplicated validation across layers |
| 4   | Coupling & Abstraction           | 28       | warning / info        | Behaviour size, single-impl protocols, type-dispatching case, external deps without behaviour, broad imports, unused deps, god contexts, mockability score, feature envy, speculative generality, parallel hierarchies, primitive obsession, mixed concerns, natural seams, hand-rolled pubsub, adapters without behaviour, unbounded external calls, missing telemetry, unprotected bang calls, **compiled**: unused imports, weak dependency, protocol completeness, internal module leak, phantom dependency |
| 5   | OTP Process Architecture         | 43       | error / warning / info | Unsupervised processes, GenServer hygiene, blocking init/callbacks, supervision tree shape, restart strategies, Task discipline, ETS patterns, process-naming safety, bottlenecks, tracing safety, GenStage backpressure, stale PIDs, deadlock detection, missing handle_info, brutal kill, ETS ownership leak, hardcoded timeouts, sequential-where-parallel, **callback sprawl** |
| 6   | Module Quality                   | 53       | error / warning / info | Module cohesion, function complexity & arity, struct field count, file length, function fan-out, boolean flag args, pretentious names, distance from main sequence, error handling (7 rules), nesting depth, if/else dispatch, recursion (4 rules), stub functions, buried try/rescue, **LLM slop detection** (5 sub-checks), dead private functions, unreachable clauses, constant expressions, defensive nil returns, identity transformations, verbose ok/error unwrap, single-clause with, redundant guard rechecks, long parameter lists, nested control flow, boolean blindness, **shadowed clauses** (pattern subsumption), **over-eager evaluation** (6 sub-checks), **sensitive data exposure** (6 sub-checks), **compiled**: dead code, transitive dead code, API surface weight, non-exhaustive API, inconsistent return shapes, degenerate functions, lookup table candidates |
| 7   | Test Architecture                | 24       | warning / info        | Test mirrors source, Repo in tests, mocks need behaviours, async eligibility, sleep in tests, test naming, no/trivial assertions, long setup/test bodies, Mox verification, coverage gap, mocking own modules, runtime DI, generic test names, weak assertions, missing cleanup, hardcoded test data, **over-mocking**, **empty describe blocks**, **missing error path tests**, **untested modules**, **compiled**: test-only public functions |
| 8   | Event Sourcing                   | 8        | error / warning / info | Command/event naming, **pure aggregate apply/2**, immutable events, shared projections, events need `Jason.Encoder`, projector reads external/non-deterministic, process manager reads projection, aggregates without Commanded behaviour |
| 9   | State Machine                    | 3        | warning / info        | Unreachable states, terminal state integrity, implicit state via boolean flags |
| 10  | Composition                      | 2        | info                  | Deep `use` chains, excessive namespace nesting                                  |
| 11  | Native Interop                   | 4        | warning / info        | NIF without behaviour boundary, missing dirty scheduler config, panic patterns in Rust NIFs, NIF doing I/O when Port would be safer |

**Severity meanings (used by all rules):**

| Severity   | Meaning                                                                      | CLI exit code |
|------------|------------------------------------------------------------------------------|---------------|
| `:error`   | Almost always a bug.                                                         | 2             |
| `:warning` | Almost always wrong, but may have legitimate exceptions.                     | 1             |
| `:info`    | Architectural smell, often a judgment call. For human review.                | 0             |

**Discoverable from the MCP server:**

```jsonc
// archdo_list_rules → returns id, category, description, module
// archdo_explain_rule → returns the canonical description for one rule id
```

### 3.1 Precision improvements (May 2026)

Six rules saw precision-improving changes that reduce false-positive load. None of these are new rules — they're sharper detection on existing rules. If you saw noise from any of these in earlier versions, re-run; the new behaviour is the default. Each subsection below covers what the rule used to flag, what it flags now, the reasoning behind the change, and worked examples.

#### 3.1.1 Rule 1.6 — Cross-cutting in domain (Phoenix-aware layer detection)

**What it measures:** the count of `Logger.{debug,info,notice,warning,warn}` calls in a single module. Above threshold (default 3, configurable via `.archdo.exs` `thresholds:`), the module is considered to be doing cross-cutting work in domain code rather than at a boundary.

**What changed:** previously the rule used hand-rolled `web_file?`, `adapter_file?`, and `infrastructure_file?` predicates that matched on path substrings (`_web/`, `web/`, `/adapter`, `/infrastructure/`, `_client.ex`, etc.). These missed entire layer categories — most notably operational code (Mix tasks, release scripts, data migrations, seed scripts) where Logger noise is *appropriate* and not a domain-layer smell. The rule now consumes `Archdo.Phoenix.classify_file/2`, the shared layer classifier, and exempts these layers:

```
:operational | :test | :application_root | :web | :controller |
:live_view | :router | :component | :infrastructure | :migration
```

**Why:** the Phoenix classifier already encodes file-layer knowledge with much broader coverage (Mix.Task detection via `use Mix.Task`, release scripts via `release.ex` filename, data migrations via `data_migration/` path, application root via `use Application`). Reusing it eliminated 3 substring helpers and brought in correct exemptions for Mix tasks the original predicates missed. The rule still fires on real domain modules with excessive Logger calls.

**Triggers (BAD — domain module with 4+ Logger calls):**

```elixir
defmodule MyApp.Accounts do
  def create(attrs) do
    Logger.info("Validating attrs")
    Logger.debug("Attrs: #{inspect(attrs)}")
    Logger.info("Creating account")
    Logger.info("Account created")
    {:ok, attrs}
  end
end
# → CE-1.6: Domain module MyApp.Accounts contains 4 Logger calls
```

**Doesn't trigger (GOOD — same code in operational layer):**

```elixir
defmodule Mix.Tasks.MyApp.Migrate do
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Logger.info("Starting migration")
    Logger.info("Pre-checks passed")
    Logger.info("Running migration step 1")
    Logger.info("Done")
    :ok
  end
end
# → No diagnostic. Mix tasks ARE the cross-cutting boundary;
#   logging there is exactly where it belongs.
```

**Configuration:** raise the threshold in `.archdo.exs` if your domain modules legitimately need 4-5 Logger calls (rare):

```elixir
thresholds: [{"1.6", max_logger_calls: 5}]
```

**When it's still a false positive:** rare. If a module truly belongs in the domain but emits 4+ Logger calls for one inherent reason (e.g., an audit-log writer that must log each step), use the threshold knob rather than the rule. There's no per-module suppression marker for 1.6 — the domain/operational classification is the architectural decision; if you disagree with it, override the layer classifier via `.archdo.exs`.

---

#### 3.1.2 Rule 1.9 — Time injection (default-arg exemption)

**What it measures:** direct calls to wall-clock primitives (`DateTime.utc_now/0`, `Date.utc_today/0`, `NaiveDateTime.utc_now/0`, `Time.utc_now/0`, `System.system_time/0`, `System.monotonic_time/0`, `System.os_time/0`, `Calendar.universal_time/0`) in domain code that doesn't accept an injected clock.

**What changed:** the rule's own recommended fix is `def schedule(event, now \\ DateTime.utc_now()) do ... end` — accept the current time as a function argument with the wall-clock as the default. Production callers use the default; tests pass an explicit timestamp. The rule used to flag the default-arg expression itself, which defeated the suggested fix. Now the rule walks every `def`/`defp` head, finds `{:\\, _, [pattern, default_expr]}` nodes, recurses into the default to collect time-call line numbers, and excludes those lines from the diagnostic set.

**Why:** flagging the recommended pattern produces a no-win situation — the developer either ignores the rule or reverts the fix. The exemption preserves the rule's intent (catch hardcoded clock dependencies in function bodies) while permitting the injection mechanism the rule itself recommends.

**Triggers (BAD — body call):**

```elixir
defmodule MyApp.Scheduler do
  def schedule(event) do
    now = DateTime.utc_now()              # ← body call, fires CE-1.9
    %{event: event, scheduled_at: now}
  end
end
```

**Doesn't trigger (GOOD — default-arg injection):**

```elixir
defmodule MyApp.Scheduler do
  def schedule(event, now \\ DateTime.utc_now()) do
    %{event: event, scheduled_at: now}
  end
end
# → No diagnostic. The default-arg IS the injection mechanism
#   the rule recommends.
```

**Still triggers (BAD — both default arg AND body call):**

```elixir
defmodule MyApp.Scheduler do
  def schedule(event, now \\ DateTime.utc_now()) do
    actual_now = DateTime.utc_now()       # ← body call, still fires
    %{event: event, default: now, actual: actual_now}
  end
end
# → CE-1.9 fires on line 3, NOT on the default arg.
```

**Edge case — multiple default args, single time call:** the rule deduplicates per `{module, function}`, so a module with `DateTime.utc_now/0` in N defaults emits at most one diagnostic per function (and zero if all calls are in defaults).

---

#### 3.1.3 Rule 3.1 — Duplicated code (umbrella sibling downgrade)

**What it measures:** Type-2 clones — structurally identical functions across modules. The rule normalizes function bodies (strips metadata, replaces variable references with positional placeholders), hashes them, and groups by hash. Functions sharing a hash are reported as duplicates. Minimum AST node count: 15 (filters out trivial getters/setters).

**What changed:** in umbrella projects, the same function often appears in multiple sibling apps by deliberate design — parallel implementations across deployables (api / edge), shared schema field definitions, mirrored helpers across web / worker apps. These cross-app clones are usually intentional and need to evolve in lockstep, which is the opposite of "extract to shared module." The rule now downgrades cross-app clones from `:warning` to `:info` while keeping intra-app clones at `:warning`.

**Detection of "umbrella sibling app"** is path-based: a file at `apps/<app_name>/lib/...` or any path containing the segment `apps/<app_name>/`. Two clones are "cross-app" iff their `<app_name>` segments differ. Non-umbrella projects (no `apps/` prefix) get the original `:warning` severity for all clones.

**Why:** umbrella siblings are a legitimate architectural pattern — Phoenix Channels and JSON APIs often need the same encoder code, but in physically separate apps. Forcing extraction creates a third app (the shared library) with its own deployment dependencies, which is typically a worse trade than accepting the duplication. The `:info` severity preserves the signal (you should know about the clones) without elevating them above intra-app duplication, which is almost always real debt.

**Triggers as `:warning` (BAD — same-app clone):**

```
lib/my_app/orders.ex            # MyApp.Orders.calculate_total/1
lib/my_app/invoices.ex          # MyApp.Invoices.compute_amount/1
                                # ↑ structurally identical, same app
                                # → :warning, "extract to shared helper"
```

**Triggers as `:info` (cross-app, intentional):**

```
apps/api/lib/api/orders.ex      # Api.Orders.calculate_total/1
apps/edge/lib/edge/orders.ex    # Edge.Orders.calculate_total/1
                                # ↑ structurally identical, sibling apps
                                # → :info, "consider whether to share"
```

**When the downgrade is wrong:** when the cross-app clones are NOT deliberate (someone copy-pasted across apps without realizing). The `:info` is then under-reporting. Currently no escape hatch — file an issue if the over-broad downgrade produces false negatives in your project.

---

#### 3.1.4 Rule CE-11 — Contract density (test_density sub-score)

**What it measures:** a module representing an irreversible decision (Ecto schema, supervisor, public-API path) whose contract density is dramatically below the codebase median on at least one of three sub-scores: spec coverage, doc coverage, OR test density. Fires when any sub-score is below 50% of its respective cohort median.

**What changed:** v1 scored only spec coverage and doc coverage. Test density was deferred at the M28 ship because the project-level analysis didn't pair source files with test files. M-Plan10 adds test density via the Mix convention (`lib/foo/bar.ex` paired with `test/foo/bar_test.exs`). The cohort minimum was also lowered from 3 modules to 2, since test density is per-module signal that doesn't need a large cohort.

**Test density formula:** `min(1.0, test_count / public_function_count)`. Test count is the number of `test "name" do ... end` blocks in the paired test file. Capped at 1.0 so a module with 5 publics and 10 tests doesn't outweigh modules with reasonable test counts. The rule does NOT count `describe` blocks separately — the per-test count is what matters.

**Why:** an Ecto schema with 100% spec coverage but no paired test file ships an irreversible-decision module without a regression guard. The combined three-dimensional view catches this case the original two-dimensional view missed.

**Triggers (BAD — schema with no test file):**

```
lib/myapp/billing/invoice.ex    # Invoice schema, has @spec + @doc
test/myapp/billing/             # ← no invoice_test.exs

# Cohort: 3 other schemas have invoice_test.exs / customer_test.exs / etc.
# Median test_density = 1.0
# Invoice's test_density = 0.0
# Floor (50% of median) = 0.5
# 0.0 < 0.5 → fires CE-11 with "test density 0% (median 100%)"
```

**Doesn't trigger (GOOD — paired test file exists):**

```
lib/myapp/billing/invoice.ex
test/myapp/billing/invoice_test.exs   # ≥ 1 test "..." block
```

**Marker exemption:** `@archdo_skip_contract_check "internal-only embedded shape"` if the module looks irreversible (uses `Ecto.Schema`, `use Supervisor`, or sits on a configured public-API path) but is genuinely internal. See §3.2.

**Cohort minimum:** the rule now needs only 2 candidate modules (schemas/supervisors/public-API paths) before it fires. Single-candidate projects still get no signal — a one-element median is degenerate.

---

#### 3.1.5 Rule CE-50 — :ok loses info (transitively-threaded detection)

**What it measures:** a function that returns the bare atom `:ok` after performing work that produced a richer result (`{:ok, value}`, an inserted struct, an HTTP response, a Mailer.deliver result). Callers can't distinguish "succeeded with this result" from "succeeded with no result"; subsequent operations needing the result must re-fetch.

**What v1 caught (still fires):**

1. Pattern-match-then-discard:
   ```elixir
   def create(attrs) do
     {:ok, _user} = Repo.insert(%User{} |> User.changeset(attrs))
     :ok
   end
   ```
2. Bare bang call followed by `:ok`:
   ```elixir
   def save(attrs) do
     Repo.insert!(%User{} |> User.changeset(attrs))
     :ok
   end
   ```
3. Bound-and-unused (M-Aux2):
   ```elixir
   def go(id) do
     result = Repo.get(Order, id)        # bound, never used
     :ok
   end
   ```

**What M-Plan9 added (new this session):**

4. Transitively-threaded chain:
   ```elixir
   def go(id) do
     result = Repo.get(Order, id)
     process(result)                     # uses result — chain ends here
     :ok                                 # ← richer value still discarded
   end
   ```

**Why the v1 logic missed case 4:** the v1 `bound_richer_unused?/1` predicate explicitly checked "does `result` appear in any subsequent statement?" If yes, it bailed — assuming the value was used productively. But "used in `process(result)`" is meaningless when `process(result)`'s return value is discarded by the function returning `:ok` literal. The chain literally cannot escape to the return position regardless of how many leaf calls reference the var.

**The new logic** (`binds_richer?/1`): when the function returns `:ok` literal AND the prefix contains ANY `var = richer_call(...)` assignment, fire — regardless of whether `var` is referenced downstream. The body-returns-`:ok`-literal precondition is the safety check: if the chain DOES escape (`{:ok, processed}` return, for example), the outer `body_returns_lossy_ok?/1` filter exits before the binding check runs.

**Doesn't trigger (GOOD — chain escapes via the return):**

```elixir
def go(id) do
  result = Repo.get(Order, id)
  processed = process(result)
  {:ok, processed}                      # ← return contains derived value
end
```

**Doesn't trigger (GOOD — intentional discard):**

```elixir
def go(id) do
  _result = Repo.get(Order, id)         # ← _ prefix = intentional discard
  :ok
end
```

**Marker exemption:** `@archdo_fire_and_forget true` on the module when the operation is genuinely fire-and-forget and the richer value is uninteresting to callers (cache invalidation, notification dispatch).

**Why this matters at scale:** the change found ~15 additional findings in the field cohort that v1 missed. Most were the "transform-then-discard" pattern in mailers and webhook handlers where someone added a transformation step but forgot to update the function's contract.

---

#### 3.1.6 Rule CE-57 — Unguarded building block (module-verdict propagation)

**What it measures:** a function whose building-block score is ≥ 0.9 on the existing six structural components (input_closure, determinism, output_completeness, totality, side_effect_free, errors_as_values) but whose head does NOT constrain its input domain. A function `def discount(price, rate), do: max(0, price - round(price * rate))` scores 1.0 on every existing component but crashes on `discount("foo", :bar)` deep in the body with `ArithmeticError` — illegal input becomes an opaque crash instead of an expected error.

**What changed:** the per-function CE-57 finding existed since M-Aux6 (April 2026). M-Plan6 propagates the input-safety verdict to `Blackbox.module_verdict/1` — the engine behind `mix archdo --building-blocks`. Previously a module with one unguarded fn could still appear as `:building_block` in the audit output, contradicting the per-function CE-57 finding. Now the module verdict combines:

1. **Structural check:** every public fn ≥ 0.9 on the 6-component score
2. **Input-safety check:** every public fn (arity > 0) constrains its input via `Archdo.InputGuard`

The leak shape gained a new reason value `:unguarded_input` alongside the existing `float()` (structural score). Leak entries are `{atom, arity, leak_reason}` where `leak_reason :: float | :unguarded_input`. Backwards-compatible at the pattern level — existing callers matching `{n, a, _}` continue to work.

**Definition of "constrained input":** a clause is constrained when AT LEAST ONE of:
- the head has a `when` guard
- all argument patterns are specific (no bare-variable args)
- the body's last expression is an `{:error, _}` literal (clause is the explicit error fallback)

A function is well-guarded when EVERY clause is constrained. The rule fires when ANY clause is unconstrained.

**Triggers (BAD — bare-variable arg, no guard):**

```elixir
defmodule MyApp.Pricing do
  @spec discount(integer(), float()) :: integer()
  def discount(price, rate), do: max(0, price - round(price * rate))
end
# → CE-57: discount/2 accepts unguarded input.
#   discount("foo", :bar) crashes deep with ArithmeticError instead
#   of returning {:error, :invalid_input}.
# → Module no longer appears in --building-blocks ✓ list.
```

**Doesn't trigger (GOOD — guard constrains domain):**

```elixir
defmodule MyApp.Pricing do
  @spec discount(integer(), float()) :: integer()
  def discount(price, rate)
      when is_integer(price) and is_number(rate) and rate >= 0 do
    max(0, price - round(price * rate))
  end
end
# → No diagnostic. Module appears in --building-blocks ✓.
```

**Doesn't trigger (GOOD — explicit error fallback):**

```elixir
defmodule MyApp.Pricing do
  def discount(price, rate)
      when is_integer(price) and is_number(rate), do: max(0, price - round(price * rate))

  def discount(_, _), do: {:error, :invalid_input}    # ← fallback clause
end
```

**Doesn't trigger (GOOD — all-specific patterns):**

```elixir
defmodule MyApp.Status do
  def label(:active), do: "Active"
  def label(:pending), do: "Pending"
  def label(:cancelled), do: "Cancelled"
end
# → No bare variables; every clause is specific.
```

**Marker exemption:** `@archdo_no_input_check "all callers pre-validate via context"` when the function is internal-only and the caller's contract enforces the domain. See §3.2.

**Why this matters at the module level:** the `--building-blocks` audit is a hiring signal. A team scanning their audit output for "modules safe to property-test" needs the verdict to be honest — if the audit lists a module with one unguarded function, the recommendation is wrong. The propagation closes that gap.

---

#### 3.1.7 Graph extraction enhancements (broaden CE-30 / CE-31)

Two changes to `Archdo.Graph` and `Archdo.AnchorSet` broaden the reachability analysis behind CE-30 (unanchored module) and CE-31 (unanchored island).

**M-Plan8a — `:dynamic_dispatch` edges for `apply/3`:** when the source contains `apply(MyApp.Target, :run, [arg])` with a literal module alias as the first argument, the graph emits a new edge type `:dynamic_dispatch` from the calling module to the target. The reachability walker uses ALL edge types, so modules referenced only via apply/3 are no longer orphans.

```elixir
defmodule MyApp.Dispatcher do
  def call(arg), do: apply(MyApp.Target, :run, [arg])
end
# → Graph emits edge: MyApp.Dispatcher --[:dynamic_dispatch]--> MyApp.Target
# → MyApp.Target now reachable from anchors that reach MyApp.Dispatcher.
```

Variable targets (`apply(mod, :run, [arg])` where `mod` is a parameter or local binding) are silently skipped — there's no static resolution for the target module. This is correct: the graph should not invent edges it can't prove.

**M-Plan8b — nested `use Supervisor` / `use DynamicSupervisor` modules:** previously the supervisor-children walker only fired on modules with `use Application` (the app root). Sub-supervisors anywhere else in the tree were invisible — their child lists weren't anchored, so children appeared as orphans even though they were transitively anchored via the app's main supervisor.

The walker now recognizes any module with `use Supervisor`, `use DynamicSupervisor`, or `use Application` as a supervisor module. The supervisor module itself is added as an anchor (its existence is justified by the framework supervision contract); its `init/1` child list contributes anchors per the existing children-extraction logic.

```elixir
# Previously: only application.ex had its children anchored.
defmodule MyApp.WorkersSupervisor do
  use Supervisor

  def init(_) do
    children = [MyApp.RateLimiter, MyApp.Cache]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
# → Now: MyApp.WorkersSupervisor + MyApp.RateLimiter + MyApp.Cache
#   are all anchored. Previously only the supervisor itself
#   (if anchored from elsewhere) was visible; children were lost.
```

**Net effect:** CE-30 self-analysis dropped from 39 to a smaller number (exact count depends on the subset of the project where `apply/3` and nested supervisors appear). On the field cohort, the change predominantly affects projects with plug-style dispatch (Phoenix routers, custom router macros) and nested supervision trees (e.g., libraries that ship their own sub-supervisor).

### 3.2 Per-module suppression markers

Rules expose intentional-pattern markers as module attributes. When a rule fires on something a developer has already considered and accepted, mark the module to suppress further alerts. Markers are **opt-in declarations**, not silencing — they explicitly document the architectural choice. A reviewer reading the marker should understand both that the rule *would have* fired and *why* the pattern is intentional.

#### 3.2.1 Marker mechanics

A marker is a module attribute. To prevent the Elixir 1.18+ "module attribute set but never used" warning, register the attribute first via `Module.register_attribute/3` with `persist: true`. The `persist: true` flag puts the marker in BEAM metadata where Archdo's static analysis can find it without any runtime use:

```elixir
defmodule MyApp.SecretsVault do
  use GenServer

  # Required: register the attribute as persistent, OR Elixir
  # warns "module attribute @archdo_opaque_state was set but
  # never used" at compile time.
  Module.register_attribute(__MODULE__, :archdo_opaque_state, persist: true)
  @archdo_opaque_state "contains operator secrets — operators run with elevated access"

  # ... GenServer callbacks ...
end
```

The `register_attribute/3` line goes ABOVE the `@archdo_X` assignment. Order matters: the attribute must be registered before it's set. A common idiom is to place all `Module.register_attribute/3` calls together at the top of the module body, just below `use GenServer` (or whatever framework `use` is appropriate).

Markers are **declarations, not silencers** — they document a deliberate architectural choice, not a desire to mute the rule. When the situation changes (you add a public observer to an `@archdo_opaque_state` GenServer; you wire telemetry into an `@archdo_no_telemetry` controller), remove the marker. Stale markers that no longer reflect reality are themselves a smell — Archdo doesn't currently flag them, but a future rule might.

The full marker table:

| Marker | Suppresses | Reason string |
|--------|------------|---------------|
| `@archdo_anchor` | CE-30, CE-31 | required |
| `@archdo_aspect_aggregator` | CE-25 | optional (`true` only) |
| `@archdo_boundary_rescue` | CE-49 | required |
| `@archdo_extension_point` | CE-15 | optional (`true` only) |
| `@archdo_fire_and_forget` | CE-50 | optional (`true` only) |
| `@archdo_gdpr_exempt` | CE-53 | optional |
| `@archdo_no_input_check` | CE-57 | optional |
| `@archdo_no_property` | CE-55, CE-56 | optional |
| `@archdo_no_telemetry` | CE-27 | recommended |
| `@archdo_no_trace` | CE-32 | optional |
| `@archdo_opaque_state` | CE-29 | required |
| `@archdo_pii_handled` | CE-51 | optional |
| `@archdo_policy_wrapper` | CE-15 | required |
| `@archdo_silent_error` | CE-28 | optional |
| `@archdo_skip_contract_check` | CE-11 | recommended |
| `@archdo_specs_pending` | CE-12 | recommended |
| `@archdo_volatility` | Volatility classifier | required value (`:stable` / `:volatile` / `:mixed`) |
| `@retention` | CE-52 | required string ("90 days", "indefinite", etc.) |
| `@requirement` / `@spec_ref` / `@trace` | CE-32 | required |

Each marker is detailed below with the code shape that triggers the rule, the marker's correct usage, and common mistakes.

#### 3.2.2 `@archdo_anchor` — CE-30 / CE-31

**Suppresses:** CE-30 (unanchored module), CE-31 (unanchored island).

**What CE-30 detects:** a module that is not transitively reachable from any anchor (Phoenix route, Mix task, supervised process, public-API path, OR another `@archdo_anchor`-marked module) via the dependency graph.

**Use the marker when:** the module IS reachable but the reachability path is invisible to the static walker. Common cases:
- Called via `:erpc` from a sibling node (cross-node dispatch)
- Called via `apply(var, :fn, args)` with a runtime-bound module (the walker can't resolve `var` statically; the apply/3 enhancement only handles literal targets)
- Listed in a runtime configuration map that drives dispatch (`@plugins [...]` consumed via `Application.get_env`)
- Referenced from external Erlang code or a NIF binding

**Triggers (BAD — module appears unanchored):**

```elixir
defmodule MyApp.NifBindings do
  # No `use Mix.Task`, `use Application`, `use Phoenix.Router`, etc.
  # Not in any supervisor child list.
  # Not on any public-API path.

  def hello, do: :world
end
# → CE-30: MyApp.NifBindings is not transitively reachable from
#   any anchor. Likely dead code or a missing anchor declaration.
```

**Doesn't trigger (GOOD — explicit anchor with reason):**

```elixir
defmodule MyApp.NifBindings do
  Module.register_attribute(__MODULE__, :archdo_anchor, persist: true)
  @archdo_anchor "called via :erpc from sibling node — see lib/my_app/cluster.ex"

  def hello, do: :world
end
```

**Common mistake:** marking a module `@archdo_anchor` because it "feels important" instead of because it's actually reachable via an invisible path. If you can't name the entry path in the reason string, the module probably IS dead code and the rule is correct.

**Cross-reference:** the alternative to marking is to wire the module into a visible entry path — add it to the application's child list, expose it via a public-API module the rule already considers an anchor, or refactor the runtime dispatch to use literal module aliases (which the M-Plan8a apply/3 enhancement now picks up).

---

#### 3.2.3 `@archdo_aspect_aggregator true` — CE-25

**Suppresses:** CE-25 (cross-cutting density).

**What CE-25 detects:** a function with body ≥ 5 expressions where >40% of body expressions are calls into cross-cutting modules (Logger, `:telemetry`, `:telemetry_metrics`, `Repo.transaction`, `Ecto.Multi`, `Retry`, `Fuse`, `:fuse`).

**Use the marker when:** the function is intentionally an aspect aggregator — its purpose IS to bundle cross-cutting concerns:
- Telemetry initializer that attaches N handlers
- Metrics router that fans out to multiple sinks
- A `setup_observability/0` style function called once at app boot

**Triggers (BAD — domain function with too much cross-cutting):**

```elixir
defmodule MyApp.Orders do
  def place(attrs) do
    Logger.info("place called")
    :telemetry.execute([:orders, :place, :start], %{}, %{})
    Repo.transaction(fn ->
      Logger.debug("inside tx")
      :telemetry.execute([:orders, :tx, :start], %{}, %{})
      # ... actual order logic, drowned in observability
    end)
  end
end
# → CE-25: 5 cross-cutting calls out of 6 body expressions = 83%
#   density. Function is doing aspect work in domain code.
```

**Doesn't trigger (GOOD — function IS an aspect aggregator):**

```elixir
defmodule MyAppWeb.Telemetry do
  Module.register_attribute(__MODULE__, :archdo_aspect_aggregator, persist: true)
  @archdo_aspect_aggregator true

  def setup do
    :telemetry.attach("phoenix-stop", [:phoenix, :endpoint, :stop], &log_request/4, nil)
    :telemetry.attach("repo-query", [:my_app, :repo, :query], &log_query/4, nil)
    :telemetry.attach("oban-job", [:oban, :job, :stop], &log_job/4, nil)
    :telemetry.attach_many("metrics", @metric_events, &emit_metric/4, nil)
    Logger.info("Telemetry handlers attached")
    :ok
  end
end
```

**Common mistake:** marking ANY module that contains a function with multiple Logger calls. The marker is for functions whose entire purpose is observability orchestration — if the function ALSO does domain work, the right fix is to extract the observability into a separate function and let the rule fire on whichever side is doing aspect work it shouldn't be.

---

#### 3.2.4 `@archdo_boundary_rescue` — CE-49

**Suppresses:** CE-49 (catch-all rescue).

**What CE-49 detects:** a bare `_` or `_var` rescue clause inside a `def` body or `try/rescue` keyword list — `rescue _ ->` or `rescue x ->` where `x` is then unused. These swallow ALL exceptions silently, hiding bugs as defaults.

**Use the marker when:** the broad rescue is at a process or system boundary where ANY uncaught exception would crash a critical resource:
- Port handler that must not let GCI errors crash the port supervisor
- NIF wrapper that translates Rust panics to error tuples (every panic shape must be caught)
- TCP/UDP frame parser at the network edge where adversarial input must not bring down the listener

**Triggers (BAD — broad rescue in domain code):**

```elixir
defmodule MyApp.Orders do
  def fetch_with_fallback(id) do
    Repo.get!(Order, id)
  rescue
    _ -> nil          # ← swallows MatchError, ArithmeticError,
                      #   DBConnection.ConnectionError, EVERYTHING.
                      #   Real bugs hide as `nil` returns.
  end
end
# → CE-49: catch-all rescue inside def. Use a specific exception
#   type or return {:error, reason} from a non-bang call.
```

**Doesn't trigger (GOOD — narrow rescue with specific types):**

```elixir
defmodule MyApp.Orders do
  def fetch_with_fallback(id) do
    case Repo.get(Order, id) do
      nil -> nil
      order -> order
    end
  end
end
```

**Doesn't trigger (GOOD — boundary rescue with marker):**

```elixir
defmodule MyApp.PortHandler do
  Module.register_attribute(__MODULE__, :archdo_boundary_rescue, persist: true)
  @archdo_boundary_rescue "GCI port — any uncaught exception kills the port supervisor"

  def handle_frame(frame) do
    decode!(frame)
  rescue
    _ -> {:error, :malformed_frame}
  end
end
```

**Common mistake:** treating a deeply-nested business function as a "boundary." The boundary is where the system meets something unpredictable — external network input, a NIF that can panic, a port that can corrupt. If you can list every exception your `rescue` needs to catch, list them by name; the marker is for the case where you genuinely cannot.

---

#### 3.2.5 `@archdo_extension_point true` — CE-15

**Suppresses:** CE-15 (wrapper over framework abstraction) for SDK/library extension-point patterns.

**What CE-15 detects:** a single-implementor behaviour whose principal call target is a framework primitive with a documented test seam (Ecto.Repo, Phoenix.PubSub, Oban, Task, Task.Supervisor, GenServer, Agent). The wrapper adds an indirection hop without policy value — the framework's own seam is sufficient.

**Use the marker when:** the behaviour exists to be implemented BY OTHER LIBRARIES or BY USERS — it's a published extension point of an SDK, not internal abstraction:
- OpenTelemetry-style: ship a `MyLib.SpanProcessor` behaviour so consumers can plug in their own
- A Phoenix-style: ship a `MyLib.Plug` behaviour for user middleware
- A protocol-as-extension: ship `MyLib.Encoder` behaviour for data type extension

**Triggers (BAD — wrapper around Repo with no policy):**

```elixir
defmodule MyApp.RepoBehaviour do
  @callback get(module(), id :: term()) :: struct() | nil
  @callback insert(struct()) :: {:ok, struct()} | {:error, Changeset.t()}
end

defmodule MyApp.Repo do
  @behaviour MyApp.RepoBehaviour
  def get(schema, id), do: MyApp.EctoRepo.get(schema, id)
  def insert(struct), do: MyApp.EctoRepo.insert(struct)
end
# → CE-15: single-implementor behaviour wrapping Ecto.Repo.
#   Ecto.Repo already has its own test seam (Ecto.Adapters.SQL.Sandbox).
#   The wrapper adds a hop without policy value.
```

**Doesn't trigger (GOOD — extension point for SDK):**

```elixir
defmodule MyOtelLib.SpanProcessor do
  Module.register_attribute(__MODULE__, :archdo_extension_point, persist: true)
  @archdo_extension_point true

  @callback on_start(span :: term()) :: :ok
  @callback on_end(span :: term()) :: :ok
end

defmodule MyOtelLib.SpanProcessor.Default do
  @behaviour MyOtelLib.SpanProcessor
  # Default impl shipped for users who don't customize.
end
```

**Common mistake:** confusing "I might want to swap this in tests" (which is what `@archdo_policy_wrapper` is for) with "this is a published extension point for third parties." The marker is specifically for SDK boundaries where the absence of a behaviour would force users to fork the library.

---

#### 3.2.6 `@archdo_fire_and_forget true` — CE-50

**Suppresses:** CE-50 (:ok loses info).

**What CE-50 detects:** a function that returns the bare atom `:ok` after performing work that produced a richer result (Repo.insert, Mailer.deliver, HTTP client call). See §3.1.5 for the full v2 detection logic.

**Use the marker when:** the operation is genuinely fire-and-forget and callers cannot use the richer result:
- Cache invalidation: callers want "tell me when the invalidation completed", not the deleted entries
- Notification dispatch: callers want "did it queue?", not the message ID for tracking
- Audit log append: the appended record is uninteresting to the caller

**Triggers (BAD — domain function discarding richer result):**

```elixir
defmodule MyApp.Orders do
  def complete(id) do
    {:ok, _order} = Repo.update(...)
    :ok
  end
end
# → CE-50: `complete/1` returns :ok after a Repo.update.
#   Callers cannot tell what was updated; subsequent operations
#   needing the order must re-fetch.
```

**Doesn't trigger (GOOD — function returns the meaningful value):**

```elixir
defmodule MyApp.Orders do
  def complete(id) do
    Repo.update(...)        # returns {:ok, order} | {:error, cs}
  end
end
```

**Doesn't trigger (GOOD — fire-and-forget with marker):**

```elixir
defmodule MyApp.CacheInvalidator do
  Module.register_attribute(__MODULE__, :archdo_fire_and_forget, persist: true)
  @archdo_fire_and_forget true

  def invalidate(key) do
    :ets.delete(:my_cache, key)
    Phoenix.PubSub.broadcast(MyApp.PubSub, "cache:invalidated", {:invalidated, key})
    :ok                     # ← intentionally :ok; callers don't care
                            #   about the deleted entries or broadcast result.
  end
end
```

**Common mistake:** marking a module fire-and-forget when only ONE function genuinely is. The marker applies to the whole module, so use it for modules whose entire purpose is fire-and-forget side effects (cache invalidator, notification dispatcher). For one-function exceptions in a mixed-purpose module, refactor the function to return the meaningful value or extract it to a dedicated module.

---

#### 3.2.7 `@archdo_gdpr_exempt` — CE-53

**Suppresses:** CE-53 (PII schema without right-to-deletion path).

**What CE-53 detects:** a schema with PII-shaped fields (email, phone, SSN, address, password*, *_token, etc.) lacking a `delete_for_*` / `forget_*` / `anonymize_*` / `erase_*` function that references the schema. Fires only with the `--gdpr-scope` CLI flag.

**Use the marker when:** the schema is genuinely GDPR-exempt:
- Audit log with regulatory retention obligation (must NOT be deletable per legal requirement)
- Anonymized data where the "PII fields" are already pseudonymized (hashes, derived keys)
- Internal-only schema that never holds real subject data

**Triggers (BAD — user schema with no deletion path):**

```elixir
defmodule MyApp.Users.User do
  use Ecto.Schema

  schema "users" do
    field :email, :string
    field :name, :string
    timestamps()
  end
end

# Project search for delete_user / forget_user / anonymize_user
# / erase_user finds nothing referencing MyApp.Users.User
# → CE-53: no right-to-deletion path for PII schema.
```

**Doesn't trigger (GOOD — deletion path exists):**

```elixir
defmodule MyApp.Users do
  def forget_user(user_id) do
    user = Repo.get!(MyApp.Users.User, user_id)
    Repo.delete!(user)
    :ok
  end
end
```

**Doesn't trigger (GOOD — exempt with marker):**

```elixir
defmodule MyApp.AuditLogs.Entry do
  use Ecto.Schema

  Module.register_attribute(__MODULE__, :archdo_gdpr_exempt, persist: true)
  @archdo_gdpr_exempt "regulatory retention — SOX 7 years, cannot delete"

  schema "audit_log" do
    field :user_email, :string
    field :action, :string
    timestamps()
  end
end
```

**Common mistake:** marking a schema GDPR-exempt because "we don't have a deletion path yet." The marker is for schemas that should NEVER have deletion paths. If you intend to add one later, use `@archdo_specs_pending` style discipline (track the work explicitly) rather than declaring exemption that won't hold.

---

#### 3.2.8 `@archdo_no_input_check` — CE-57

**Suppresses:** CE-57 (unguarded building block).

**What CE-57 detects:** see §3.1.6.

**Use the marker when:** every caller pre-validates input via a context boundary (Ecto changeset, NimbleOptions schema), so the function itself never sees illegal input:
- Internal helper called only from a public API that has already validated arguments
- Function whose callers go through a strongly-typed pipeline (`with` chain validating each step)
- Pure transformation in a context where the calling-site contract is enforced

**Triggers (BAD — public function accepts any input):**

```elixir
defmodule MyApp.Pricing do
  @spec discount(integer(), float()) :: integer()
  def discount(price, rate), do: max(0, price - round(price * rate))
end
# → CE-57: discount/2 has bare-variable args, no guard, no error
#   fallback. discount("foo", :bar) crashes deep with ArithmeticError.
```

**Doesn't trigger (GOOD — input check via guard):**

```elixir
defmodule MyApp.Pricing do
  @spec discount(integer(), float()) :: integer()
  def discount(price, rate)
      when is_integer(price) and is_number(rate), do: max(0, price - round(price * rate))
end
```

**Doesn't trigger (GOOD — internal helper with marker):**

```elixir
defmodule MyApp.Pricing do
  Module.register_attribute(__MODULE__, :archdo_no_input_check, persist: true)
  @archdo_no_input_check "all callers pre-validate via Cart.changeset/2"

  # Public — but only called from MyApp.Cart after changeset validation
  def discount(price, rate), do: max(0, price - round(price * rate))
end
```

**Common mistake:** marking the module when the actual boundary contract isn't documented or enforced. The marker is a CLAIM that callers pre-validate; if a future refactor adds a new caller that doesn't pre-validate, the marker becomes a lie. Prefer guards on the function head — they're enforced by the runtime, not by convention.

---

#### 3.2.9 `@archdo_no_property` — CE-55, CE-56

**Suppresses:** CE-55 (building-block function without property test), CE-56 (effect leak in near-building-block function).

**What CE-55 detects:** a function with building-block score ≥ 0.9 + arity > 0 + no `property "..." do ... end` block referencing the function in test files. The function is structurally a building block but only example-tested.

**What CE-56 detects:** a function where every building-block component score ≥ 0.9 EXCEPT side_effect_free, AND ≤ 2 observability-only side effects (Logger / `Phoenix.PubSub.broadcast` / `:telemetry.execute|span`). The function is one extracted side-effect away from being a building block.

**Use the marker when:** the function's purpose IS to produce an observability effect, OR property testing is impractical:
- Logger/telemetry emitter where the "side effect" IS the function's contract
- Function whose input domain is too rich for StreamData generators (complex AST nodes, file system trees)
- Function with deliberate non-determinism (UUID generation, timestamp emission)

**Triggers CE-56 (BAD — near-building-block with single Logger leak):**

```elixir
defmodule MyApp.Pricing do
  @spec discount(integer(), float()) :: integer()
  def discount(price, rate)
      when is_integer(price) and is_number(rate) and rate >= 0 do
    Logger.debug("discount: price=#{price} rate=#{rate}")    # ← single side effect
    max(0, price - round(price * rate))
  end
end
# → CE-56: function passes 5/6 components; the lone Logger
#   call is the only thing keeping it from being a building block.
#   Suggest: split into pure inner + thin Logger wrapper.
```

**Doesn't trigger (GOOD — split into pure + wrapper):**

```elixir
defmodule MyApp.Pricing do
  @spec discount(integer(), float()) :: integer()
  def discount(price, rate)
      when is_integer(price) and is_number(rate) and rate >= 0 do
    max(0, price - round(price * rate))
  end

  def discount_with_log(price, rate) do
    result = discount(price, rate)
    Logger.debug("discount: price=#{price} rate=#{rate} result=#{result}")
    result
  end
end
```

**Doesn't trigger (GOOD — observability is the purpose):**

```elixir
defmodule MyApp.Telemetry.RequestEmitter do
  Module.register_attribute(__MODULE__, :archdo_no_property, persist: true)
  @archdo_no_property "function's job IS to emit telemetry; no pure version exists"

  def emit_request_event(method, path, latency) do
    :telemetry.execute([:my_app, :request], %{latency: latency}, %{method: method, path: path})
    :ok
  end
end
```

**Common mistake:** marking a module to silence CE-55 because "we'll add property tests later." Prefer adding the tests — most pure transformations have a 1-line StreamData property (`check all x <- integer(), do: assert process(x) >= 0`). The marker is for cases where property testing is genuinely impossible, not delayed.

---

#### 3.2.10 `@archdo_no_telemetry` — CE-27

**Suppresses:** CE-27 (boundary telemetry).

**What CE-27 detects:** Phoenix controller actions, `Mix.Task` `run/1,2`, and `Oban.Worker` `perform/1` callbacks not wrapped in `:telemetry.span` or `:telemetry.execute`. LiveView callbacks are exempt by spec (Phoenix.LiveView.Channel emits its own telemetry).

**Use the marker when:** telemetry IS being emitted, but it's centralized one layer up from the boundary:
- Phoenix controllers covered by a `MyAppWeb.Plugs.Telemetry` plug in the router pipeline
- Oban workers covered by an Oban telemetry handler attached at app boot
- Mix tasks covered by a Mix.Task wrapper or supervisor instrumentation

**Triggers (BAD — controller without telemetry):**

```elixir
defmodule MyAppWeb.OrderController do
  use MyAppWeb, :controller

  def show(conn, %{"id" => id}) do
    order = MyApp.Orders.get!(id)
    render(conn, :show, order: order)
  end
end
# → CE-27: show/2 not wrapped in :telemetry.span. Latency, error
#   rates, throughput cannot be measured at this boundary.
```

**Doesn't trigger (GOOD — telemetry inline):**

```elixir
def show(conn, %{"id" => id}) do
  :telemetry.span([:orders, :show], %{id: id}, fn ->
    order = MyApp.Orders.get!(id)
    {render(conn, :show, order: order), %{}}
  end)
end
```

**Doesn't trigger (GOOD — centralized via plug, marker declared):**

```elixir
defmodule MyAppWeb.OrderController do
  use MyAppWeb, :controller
  Module.register_attribute(__MODULE__, :archdo_no_telemetry, persist: true)
  @archdo_no_telemetry "covered by MyAppWeb.Plugs.Telemetry in router pipeline :api"

  def show(conn, %{"id" => id}) do
    order = MyApp.Orders.get!(id)
    render(conn, :show, order: order)
  end
end
```

**Common mistake:** marking every controller `@archdo_no_telemetry` because "we have a plug somewhere." The reason string MUST name the actual covering layer — when the plug is removed during a refactor, the markers become incorrect, and the team has no way to find them. Always name the specific module in the reason string.

**Future enhancement:** a deferred milestone will discover telemetry-emitting plugs in the router pipeline automatically and exempt the controllers they cover, making this marker mostly redundant.

---

#### 3.2.11 `@archdo_no_trace` — CE-32

**Suppresses:** CE-32 (missing traceability annotation).

**What CE-32 detects:** public function on a configured `traceability_required_paths` (e.g., `lib/my_app/billing/`) without `@requirement`, `@spec_ref`, or `@trace` annotations linking it to an external requirement.

**Use the marker when:** the function is a non-traced helper that doesn't correspond to any single requirement:
- Internal utility function on a traceability-required path
- Test fixture / setup helper colocated with billing code
- Generated code that has no source-of-truth requirement

**Triggers (BAD — billing function without trace):**

```elixir
defmodule MyApp.Billing.Charges do
  def calculate_total(items), do: Enum.reduce(items, 0, &(&1.amount + &2))
end
# → CE-32 (with --traceability-required-paths "lib/my_app/billing"):
#   calculate_total/1 lacks @requirement / @spec_ref / @trace.
```

**Doesn't trigger (GOOD — traced):**

```elixir
defmodule MyApp.Billing.Charges do
  @requirement "REQ-FIN-042"
  @spec calculate_total(list()) :: non_neg_integer()
  def calculate_total(items), do: Enum.reduce(items, 0, &(&1.amount + &2))
end
```

**Doesn't trigger (GOOD — utility marker):**

```elixir
defmodule MyApp.Billing.Charges do
  Module.register_attribute(__MODULE__, :archdo_no_trace, persist: true)
  @archdo_no_trace "internal utility — no source requirement"

  def calculate_total(items), do: Enum.reduce(items, 0, &(&1.amount + &2))
end
```

---

#### 3.2.12 `@archdo_opaque_state` — CE-29

**Suppresses:** CE-29 (process state without inspection hook).

**What CE-29 detects:** a long-running stateful process (`use GenServer`, `use Agent`, `@behaviour :gen_statem`) without `format_status/1,2`. Operators cannot inspect process state during incident response (`:sys.get_state/1` returns the raw struct, which may be unreadable, contain secrets, or be unhelpfully verbose).

**Use the marker when:** process state is intentionally opaque:
- Transient buffer (compilation tracer, event collector) where state is uninteresting after the process stops
- Process holding secrets (auth vault, encryption key cache) where leaking state to logs IS the security problem
- Process where no external observers exist by design (internal worker started and stopped within a single request)

**Triggers (BAD — GenServer without format_status):**

```elixir
defmodule MyApp.SecretsCache do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  # No format_status/1
end
# → CE-29: state is opaque to operators. Add format_status/1
#   returning a sanitized view, or mark @archdo_opaque_state.
```

**Doesn't trigger (GOOD — format_status defined):**

```elixir
defmodule MyApp.SecretsCache do
  use GenServer
  # ... start_link, init ...

  @impl true
  def format_status(_status) do
    %{cached_keys: state |> Map.keys() |> length(), values: "[REDACTED]"}
  end
end
```

**Doesn't trigger (GOOD — opaque-by-design with marker):**

```elixir
defmodule Archdo.Compiled.Collector do
  use GenServer
  Module.register_attribute(__MODULE__, :archdo_opaque_state, persist: true)
  @archdo_opaque_state "transient compilation buffer; no external observers"

  # ... start_link, init, handle_call ...
end
```

**Common mistake:** marking long-running production GenServers `@archdo_opaque_state` because "we don't want to write `format_status`." The marker is for processes where state IS opaque by architectural intent. Production-critical processes should have `format_status` even if the implementation is just `%{stats: state.stats, secrets: "[REDACTED]"}` — operators need ANYTHING to look at during an incident.

---

#### 3.2.13 `@archdo_pii_handled` — CE-51

**Suppresses:** CE-51 (PII field without designated handling).

**What CE-51 detects:** an Ecto schema with PII-shaped fields (email, phone, SSN, address, dob, date_of_birth, national_id, tax_id; password* prefix; passport* prefix; *_token suffix) without `@derive {Inspect, except: [pii_field, ...]}`. Without the derive, PII appears in inspect output, error logs, and IEx sessions.

**Use the marker when:** PII fields use a non-standard but auditable handling pattern:
- Custom `Inspect` implementation (not via `@derive`) that redacts differently per field
- Schema where PII fields are encrypted at the Ecto type level (`Ecto.Type` that returns a placeholder from `dump/1`)
- Test-only schemas where PII is fixture data

**Triggers (BAD — schema with PII in inspect output):**

```elixir
defmodule MyApp.Users.User do
  use Ecto.Schema

  schema "users" do
    field :email, :string
    field :password_hash, :string
    timestamps()
  end
end
# → CE-51: email / password_hash appear in `inspect(user)` output.
#   Add @derive {Inspect, except: [:email, :password_hash]}.
```

**Doesn't trigger (GOOD — derived inspect):**

```elixir
defmodule MyApp.Users.User do
  use Ecto.Schema

  @derive {Inspect, except: [:email, :password_hash]}
  schema "users" do
    field :email, :string
    field :password_hash, :string
    timestamps()
  end
end
```

**Doesn't trigger (GOOD — custom handling with marker):**

```elixir
defmodule MyApp.Users.User do
  use Ecto.Schema
  Module.register_attribute(__MODULE__, :archdo_pii_handled, persist: true)
  @archdo_pii_handled "custom Inspect impl — see lib/my_app/users/user/inspect_impl.ex"

  schema "users" do
    field :email, MyApp.EncryptedField
    field :password_hash, MyApp.EncryptedField
    timestamps()
  end

  defimpl Inspect do
    def inspect(_, _), do: "#User<[REDACTED]>"
  end
end
```

---

#### 3.2.14 `@archdo_policy_wrapper` — CE-15

**Suppresses:** CE-15 (wrapper over framework abstraction).

**What CE-15 detects:** see §3.2.5.

**Use the marker when:** the wrapper enforces policy the framework doesn't:
- Auth wrapper that adds permission checks before delegating to Repo
- Rate-limited HTTP client wrapper that throttles outgoing requests
- Audit-logging Mailer wrapper that records every send

**Triggers (BAD — Repo wrapper with no policy):**

```elixir
defmodule MyApp.Repo do
  def get(schema, id), do: MyApp.EctoRepo.get(schema, id)
  def insert(struct), do: MyApp.EctoRepo.insert(struct)
end
# → CE-15: thin wrapper over Ecto.Repo with no added policy.
```

**Doesn't trigger (GOOD — policy wrapper with marker):**

```elixir
defmodule MyApp.AuthorizedRepo do
  Module.register_attribute(__MODULE__, :archdo_policy_wrapper, persist: true)
  @archdo_policy_wrapper "enforces tenant isolation on every query"

  def get(schema, id, tenant_id) do
    schema
    |> where([x], x.tenant_id == ^tenant_id)
    |> MyApp.EctoRepo.get(id)
  end
end
```

---

#### 3.2.15 `@archdo_silent_error` — CE-28

**Suppresses:** CE-28 (error path without log).

**What CE-28 detects:** a function returning `{:error, _}` literal OR containing a `rescue` clause without an in-scope `Logger.error/warning/info/debug/notice` call.

**Use the marker when:** errors are deliberately returned unlogged for caller-side handling:
- Pure validation function that returns `{:error, reason}` and lets the caller decide whether to log
- Layer that intentionally bubbles errors silently (logging would be redundant — the boundary above already logs)

**Triggers (BAD — error path with no log):**

```elixir
defmodule MyApp.Orders do
  def fetch(id) do
    case Repo.get(Order, id) do
      nil -> {:error, :not_found}     # no log
      order -> {:ok, order}
    end
  end
end
# → CE-28: error path returns {:error, :not_found} without Logger.
```

**Doesn't trigger (GOOD — error logged):**

```elixir
def fetch(id) do
  case Repo.get(Order, id) do
    nil ->
      Logger.warning("Order not found: id=#{id}")
      {:error, :not_found}
    order ->
      {:ok, order}
  end
end
```

**Doesn't trigger (GOOD — silent by design):**

```elixir
defmodule MyApp.Orders do
  Module.register_attribute(__MODULE__, :archdo_silent_error, persist: true)
  @archdo_silent_error "errors logged at boundary (controllers); domain stays silent"

  def fetch(id) do
    case Repo.get(Order, id) do
      nil -> {:error, :not_found}
      order -> {:ok, order}
    end
  end
end
```

---

#### 3.2.16 `@archdo_skip_contract_check` — CE-11

**Suppresses:** CE-11 (contract density).

**What CE-11 detects:** see §3.1.4.

**Use the marker when:** the module looks irreversible (uses `Ecto.Schema`, `use Supervisor`, sits on a public-API path) but is genuinely internal:
- `embedded_schema` for in-process state that's never persisted
- Internal supervisor that's a private detail of a parent module
- "Public" module in a deeply nested namespace that's never called from outside

**Triggers (BAD — embedded schema flagged as irreversible):**

```elixir
defmodule MyApp.Filter.State do
  use Ecto.Schema    # ← embedded, not persisted

  embedded_schema do
    field :search_term, :string
    field :sort_dir, Ecto.Enum, values: [:asc, :desc]
  end

  def changeset(state, attrs), do: cast(state, attrs, [:search_term, :sort_dir])
end
# → CE-11: low spec/doc/test coverage on what looks like an
#   irreversible decision module (uses Ecto.Schema).
```

**Doesn't trigger (GOOD — internal-shape with marker):**

```elixir
defmodule MyApp.Filter.State do
  use Ecto.Schema
  Module.register_attribute(__MODULE__, :archdo_skip_contract_check, persist: true)
  @archdo_skip_contract_check "internal-only embedded shape for in-process filter state"

  embedded_schema do
    field :search_term, :string
    field :sort_dir, Ecto.Enum, values: [:asc, :desc]
  end
end
```

---

#### 3.2.17 `@archdo_specs_pending` — CE-12

**Suppresses:** CE-12 (public API spec coverage).

**What CE-12 detects:** a candidate module (Ecto schema, supervisor, public-API path) with spec coverage below 80% on its public functions.

**Use the marker when:** specs are being added incrementally and you want to track the work:

```elixir
defmodule MyApp.Billing do
  Module.register_attribute(__MODULE__, :archdo_specs_pending, persist: true)
  @archdo_specs_pending "WIP — adding @specs in #1234"

  def list_invoices(scope), do: ...    # no spec yet
  def create_invoice(attrs), do: ...   # no spec yet
end
```

The marker is a CONTRACT with the team that the work is in flight. Reviewers should not approve a marker without a tracking link in the reason string.

---

#### 3.2.18 `@archdo_volatility` — Volatility classifier

**Sets:** the per-module volatility tag used by CE-1, CE-2, CE-3, CE-4, CE-34, CE-35.

**What the classifier does:** categorizes each module as `:stable`, `:volatile`, or `:mixed` based on the modules it depends on. A module that calls Tesla, Req, or HTTPoison is `:volatile` (depends on volatile network primitives); a module that only calls `String`, `Enum`, `Map` is `:stable`. A module mixing both is `:mixed` and a candidate for splitting (CE-4).

**Use the marker when:** the auto-classifier gets it wrong. Common cases:
- Module calls a volatile dependency in dead code or a never-executed branch
- Module's "volatile" calls are all behind a behaviour seam that the classifier doesn't see
- Test helper that calls volatile primitives but isn't really part of the system

```elixir
defmodule MyApp.HealthCheck do
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable    # despite calling Tesla in one branch

  def check, do: ...
end
```

**Common mistake:** marking modules to silence CE-1 / CE-34 / CE-35 because adding a behaviour seam is "too much work." The auto-classification is usually correct — the marker should override it only when the classification is genuinely wrong, not when the classification is correct but the fix is inconvenient.

---

#### 3.2.19 `@retention` — CE-52

**Suppresses:** CE-52 (missing retention policy).

**What CE-52 detects:** an Ecto schema with timestamps + a user-like FK (configurable: user/account/member/owner/subject/creator/author/actor) lacking `@retention` annotation OR a referencing Oban worker that performs scheduled deletion.

**Use the marker** to declare the schema's retention policy:

```elixir
defmodule MyApp.Sessions.Session do
  use Ecto.Schema
  @retention "30 days from last_used_at"

  schema "sessions" do
    field :token_hash, :string
    field :user_id, :binary_id
    field :last_used_at, :utc_datetime
    timestamps()
  end
end
```

The reason string must be human-readable AND parseable by future tooling — recommend `"<duration> from <field>"` shape, or `"indefinite — see compliance/retention.md"` for never-expires data.

---

#### 3.2.20 `@requirement` / `@spec_ref` / `@trace` — CE-32 traceability annotations

**Suppresses:** CE-32 (missing traceability annotation) for the annotated function.

**Module-level vs per-function:**
- At module level (before any `def`), the annotation covers ALL public functions
- Immediately before a specific `def`, it covers only that function

```elixir
# Module-level — covers all functions
defmodule MyApp.Billing.Charges do
  @requirement "REQ-FIN-001"
  @spec calculate(list()) :: integer()
  def calculate(items), do: ...

  @spec apply_discount(integer(), float()) :: integer()
  def apply_discount(amount, rate), do: ...
end

# Per-function — only this def is covered
defmodule MyApp.Billing.Charges do
  @requirement "REQ-FIN-001"
  @spec calculate(list()) :: integer()
  def calculate(items), do: ...

  # Not covered by REQ-FIN-001 — would fire CE-32
  @spec apply_discount(integer(), float()) :: integer()
  def apply_discount(amount, rate), do: ...
end
```

Multiple annotations per def are fine: a function can satisfy multiple requirements simultaneously. The reason string is the requirement ID — usually a JIRA ticket, a spec section, or a contract clause reference.

### 3.3 Change Economy rules + packs

The Change Economy (CE) rule family asks a different question than the core rules: not "is this code shaped right?" but "what does it cost when this code needs to change?" CE rules are organized into 4 packs:

| Pack | Rules | Default | What it measures |
|------|-------|---------|------------------|
| `core` | All 203 original rules + CE-1, CE-2, CE-3, CE-4, CE-11, CE-12, CE-15, CE-17, CE-21, CE-23, CE-24, CE-25, CE-26, CE-27, CE-28, CE-29, CE-30, CE-31, CE-34, CE-35, CE-47, CE-48, CE-49, CE-50 | **on** | Architecture quality + cost-of-change essentials |
| `ce_compliance` | CE-32 (missing traceability), CE-33 (dead requirement) | opt-in | Traceability between code and external requirements |
| `ce_privacy` | CE-51 (PII field without designated handling), CE-52 (missing retention policy), CE-53 (PII schema without right-to-deletion path) | opt-in | GDPR / data-protection signals |
| `ce_composability` | CE-54 (low-possibility-high-value building-block), CE-55 (building-block function without property test), CE-56 (effect leak in near-building-block), CE-57 (building-block candidate accepts unguarded input) | opt-in | "Could this function become a tested building block?" |

Run a pack via `--packs`:

```bash
# Default — all core rules
mix archdo --paths lib

# Add the privacy pack
mix archdo --paths lib --packs core,ce_privacy

# Just the composability pack (no core noise)
mix archdo --paths lib --packs ce_composability

# List which packs exist and which rules they contain
mix archdo --list-packs
```

Selected CE rules — what each measures and indicates:

| Rule | What it measures | What firing indicates |
|------|------------------|----------------------|
| **CE-1** Hardcoded volatile dependency | Direct call to a `:volatile`-tagged module (Tesla, Req, HTTPoison, Finch) without a behaviour seam | Test doubles can't be substituted; the volatile dependency drives the cost-of-change for every consumer |
| **CE-2/CE-3** Volatility-substitutability quadrant | Per-module 3×3 cell of `{abstraction_class} × {volatility_tag}` | CE-2: `:volatile` module without abstraction (missing seam at the boundary). CE-3: `:stable` module heavily abstracted (over-engineered stable core) |
| **CE-11** Contract density | Spec coverage + doc coverage + test density on irreversible-decision modules (schemas, supervisors, public API) vs cohort median | One sub-score below 50% of cohort median means the module is under-contracted relative to the project's own standards |
| **CE-15** Wrapper over framework | Single-implementor behaviour wrapping a framework primitive that already has a documented test seam (Ecto.Repo, Phoenix.PubSub, Oban) | The wrapper adds a hop without policy value; the framework's existing seam is sufficient |
| **CE-17** Magic literals | Atoms / integers in `==` comparisons or status-shaped field assignments (`status:`, `state:`, `kind:`) appearing in ≥2 modules | Status taxonomy isn't centralized; renaming requires coordinated change across N modules |
| **CE-23** High cognitive complexity | Per-function cognitive complexity (Campbell 2018) ≥15 (warn) or ≥25 (error) | Function has nested control flow + logical-op chains that compound reading cost beyond what cyclomatic complexity captures |
| **CE-24** Complexity shape | `{cyclomatic_band, cognitive_band}` cell classification | `:twisty` (cogn ≥10 + cogn > 2×cyclo) = nested-and-twisty. `:flat-dispatch` (cyclo ≥8 + cyclo > 2×cogn) = many clauses but each shallow — 6.2 over-counting |
| **CE-25** Cross-cutting density | >40% of body expressions are calls into Logger/telemetry/Repo.transaction/Ecto.Multi/Retry/Fuse | Function is functioning as an aspect aggregator without saying so |
| **CE-26** Scattered taxonomy | Telemetry event lists `[:user, :created]` and Logger string keys clustered by canonical token-stem | Same-concept events go by N different surface forms across modules |
| **CE-27** Boundary telemetry | Phoenix controller actions, Mix.Task `run/1`, Oban `perform/1` not wrapped in `:telemetry.span` / `:telemetry.execute` | Latency, error rates, throughput cannot be measured at the boundary |
| **CE-28** Error path without log | Function returns `{:error, _}` literal OR contains `rescue` clause without an in-scope `Logger.error/warning` | Errors disappear silently — no trace in production logs |
| **CE-29** Opaque process state | `use GenServer` / `use Agent` / `@behaviour :gen_statem` without `format_status/1,2` | Operators cannot inspect process state during incident response |
| **CE-30** Unanchored module | Module not transitively reachable from any anchor (Phoenix route, Mix task, supervised process, public API, `@archdo_anchor`) | Module exists but no entry path leads to it — likely dead code or a missing anchor declaration |
| **CE-32** Missing traceability annotation | Public function on `traceability_required_paths` lacks `@requirement` / `@spec_ref` / `@trace` | Compliance audit cannot link the code to its source requirement |
| **CE-33** Dead requirement | Requirement (from `--requirements-source <path>`) has no `@requirement` annotation referencing it anywhere in the code | Requirement was specified but never implemented — or implementation was removed |
| **CE-34** Volatile call without timeout | Tesla / Req / Finch / HTTPoison call (or any `GenServer.call/2`) without explicit timeout | Call blocks indefinitely if downstream is slow; cascading failure risk |
| **CE-35** Volatile module without retry/breaker | Function uses a volatile target without a retry helper (`Retry.with_retries`, custom) or breaker (`:fuse.ask`) in scope | Single network hiccup propagates as an exception |
| **CE-47** Bang without non-bang sibling | Public `name!/n` lacking a sibling `name/n` returning `{:ok, _} \| {:error, _}` | Forces callers into try/rescue when they want a controlled error path |
| **CE-48** Error category drift | Error atoms in `{:error, _}` literals cluster around the same canonical stem (e.g., `:not_found`, `:user_not_found`, `:no_user_found` all mean "found") | Consumers must pattern-match on every variant; renaming one requires coordinated change |
| **CE-49** Catch-all rescue | Bare `_` or `_var` rescue clause inside a `def` or `try` keyword list | All exceptions swallowed silently; bugs hide as defaults |
| **CE-50** :ok loses info | Function returns `:ok` literal after a richer-result call (Repo, Mailer, HTTP client) — bare, bound-and-unused, or transitively threaded | Callers can't distinguish "succeeded with this result" from "succeeded with no result"; subsequent operations re-fetch |
| **CE-51** PII field without designated handling | Schema with PII-shaped fields (email, phone, SSN, password*, *_token) without `@derive {Inspect, except: [...]}` | PII appears in inspect output, error logs, and IEx sessions |
| **CE-52** Missing retention policy | Schema with timestamps + user-like FK lacking `@retention` annotation OR a referencing Oban worker | Data accumulates indefinitely; GDPR right-to-erasure obligation untracked |
| **CE-53** PII schema without right-to-deletion path | PII schema with no `delete_for_*` / `forget_*` / `anonymize_*` / `erase_*` function referencing it | Cannot fulfill data-subject deletion requests |
| **CE-54** Low-possibility / high-value building-block | Function in `:context` or `:schema` layer with structural component failure AND high substance score | Function is doing real domain work but isn't structured as a building block — hardest to test, most consequential when changed |
| **CE-55** Building-block function without property test | building-block score ≥0.9 + arity > 0 + no `property "..." do ... end` block referencing the function in test files | Function is structurally a building block but only example-tested; property test would exercise the input domain |
| **CE-56** Effect leak in near-building-block | Every building-block component ≥0.9 EXCEPT side_effect_free, AND ≤2 observability-only side effects (Logger / Phoenix.PubSub.broadcast / `:telemetry.execute`) | Function is one extracted side-effect away from being a building block |
| **CE-57** Unguarded building block | building-block score ≥0.9 + arity > 0 + at least one clause has bare-variable args without guard, all-specific patterns, or `{:error, _}` fallback | Function looks like a building block but accepts any input — illegal inputs crash deep instead of returning a controlled domain error |

For the full text and rationale of every CE rule, run `mix archdo --explain CE-XX`.

#### 3.3.1 Selected CE rules — worked examples

The rules below are the highest-impact CE rules from field cohort runs. Each shows the AST shape that triggers the rule, the architectural failure mode, and a worked BAD/GOOD pair.

##### CE-15 — Wrapper over framework abstraction

**Detects:** a behaviour with exactly one implementation whose principal call target is a framework primitive that already has a documented test seam.

**Why it matters:** wrapping `Ecto.Repo` in `MyApp.RepoBehaviour` so you can swap it in tests is a common pattern from other ecosystems — but Ecto already ships `Ecto.Adapters.SQL.Sandbox` for test isolation. The wrapper costs an indirection hop on every call, an extra mock to maintain in tests, and obscures the actual data-access pattern. CE-15 catches this.

**Triggers (BAD):**

```elixir
defmodule MyApp.Repo.Behaviour do
  @callback get(module(), term()) :: struct() | nil
  @callback insert(struct()) :: {:ok, struct()} | {:error, Changeset.t()}
end

defmodule MyApp.Repo do
  @behaviour MyApp.Repo.Behaviour

  defdelegate get(schema, id), to: Ecto.Repo
  defdelegate insert(struct), to: Ecto.Repo
end
```

**Doesn't trigger (GOOD — use Ecto's own seam):**

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
end
# Test isolation via Ecto.Adapters.SQL.Sandbox.checkout/2 — no wrapper needed.
```

**Doesn't trigger (GOOD — wrapper enforces policy):**

```elixir
defmodule MyApp.AuthorizedRepo do
  Module.register_attribute(__MODULE__, :archdo_policy_wrapper, persist: true)
  @archdo_policy_wrapper "tenant isolation enforced on every query"

  def get(schema, id, tenant_id) do
    schema |> where([x], x.tenant_id == ^tenant_id) |> Ecto.Repo.get(id)
  end
end
```

##### CE-17 — Magic literals across modules

**Detects:** atom or integer literals appearing in `==`/`!=` comparisons or status-shaped field assignments (`status:`, `state:`, `kind:`, `type:`, `role:`, …) across ≥2 modules.

**Why it matters:** when `:active`, `:pending`, `:cancelled` appear scattered across 11 modules, renaming `:cancelled` to `:archived` requires a coordinated change across all 11 — and a forgotten module silently routes to a wrong code path. The status taxonomy needs ONE source of truth (`MyApp.Order.Status` module with `defstruct` or `Ecto.Enum`).

**Triggers (BAD — `:owner` literal in 15 modules):**

```elixir
# lib/my_app/teams.ex
def role(member), do: if member.role == :owner, do: :ok, else: :error

# lib/my_app/billing.ex
def can_charge?(user), do: user.role == :owner

# lib/my_app/audit.ex
def can_view_logs?(member), do: member.role == :owner

# ... 12 more files with `:owner` literal
# → CE-17: 15 occurrences of :owner across 15 modules.
#   Centralize in MyApp.Roles.
```

**Doesn't trigger (GOOD — single source):**

```elixir
defmodule MyApp.Roles do
  @owner :owner
  @member :member
  @guest :guest

  def owner, do: @owner
  def member, do: @member
  def guest, do: @guest

  def can_administer?(role), do: role == owner()
end
```

##### CE-21 — Acquire / release without bracket helper

**Detects:** public `open/close`, `acquire/release`, `subscribe/unsubscribe`, `lock/unlock`, `connect/disconnect`, or `checkout/checkin` function pairs without a `with_*/2` bracket helper. Exempts `start_link/stop` (OTP lifecycle).

**Why it matters:** when callers manually pair `open` with `close`, every error path is a leak waiting to happen. The `with_*/2` bracket pattern ensures cleanup runs even on exception:

```elixir
def with_connection(opts, fun) do
  conn = open(opts)
  try do
    fun.(conn)
  after
    close(conn)
  end
end
```

**Triggers (BAD):**

```elixir
defmodule MyApp.Lock do
  def acquire(resource), do: ...
  def release(resource), do: ...
  # No with_lock/2 helper
end

# Caller code — easy to forget release on exception path
def update_safely(resource) do
  acquire(resource)
  result = do_update(resource)
  release(resource)
  result
end
```

**Doesn't trigger (GOOD):**

```elixir
defmodule MyApp.Lock do
  def acquire(resource), do: ...
  def release(resource), do: ...

  def with_lock(resource, fun) do
    acquire(resource)
    try do
      fun.()
    after
      release(resource)
    end
  end
end
```

##### CE-29 — Opaque process state

**Detects:** see §3.2.12.

**The architectural cost:** during an incident, an operator wants to ask "what is process X holding?" via `:observer` or `:sys.get_state/1`. Without `format_status/1`, they get the raw struct — which may be:
- 50KB of cached binary data (visually unparseable)
- A struct with `:auth_token` or `:secret_key` fields (security leak in logs)
- A reference-only struct (`#PID<0.123.0>`, `#Reference<...>`) with no human meaning

`format_status/1` returns a sanitized, summarized view designed for operator inspection.

**Triggers (BAD):**

```elixir
defmodule MyApp.AuthVault do
  use GenServer

  defstruct [:secret_key, :session_tokens, :rotation_at]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(opts), do: {:ok, %__MODULE__{secret_key: opts[:key]}}
  # No format_status/1
end
# → CE-29: state opaque to operators. :sys.get_state(MyApp.AuthVault)
#   leaks the secret key in any debugging session.
```

**Doesn't trigger (GOOD):**

```elixir
defmodule MyApp.AuthVault do
  use GenServer

  defstruct [:secret_key, :session_tokens, :rotation_at]
  # ... start_link, init ...

  @impl true
  def format_status(:terminate, [_pdict, state]), do: format_status(:normal, [_pdict, state])

  @impl true
  def format_status(:normal, [_pdict, state]) do
    %{
      session_count: map_size(state.session_tokens),
      rotation_at: state.rotation_at,
      secret_key: "[REDACTED]"
    }
  end
end
```

##### CE-30 — Unanchored module

**Detects:** a module that is not transitively reachable from any anchor (Phoenix route, Mix task, supervised process, public API, `@archdo_anchor`).

**The architectural cost:** unanchored modules accumulate over time as features are removed without removing their helpers, refactors leave behind orphan modules, or runtime dispatch changes invalidate static reachability. Each unanchored module is either:
- Dead code (delete it)
- Reachable via an invisible path (mark it `@archdo_anchor` with the path documented)
- A bug (the path WAS visible until a recent refactor broke it)

CE-30 turns this into a routine audit. The May 2026 enhancements (M-Plan8a/b) reduce false positives from `apply/3` dispatch and nested supervision; the remaining hits should be examined.

**Triggers (BAD — module has no entry path):**

```elixir
defmodule MyApp.LegacyBatchProcessor do
  def process(items), do: Enum.map(items, &process_one/1)
  defp process_one(item), do: ...
end
# Project search: nothing references MyApp.LegacyBatchProcessor.
# → CE-30: unanchored. Likely removed-but-not-deleted from when
#   the team migrated to Oban workers.
```

##### CE-34 — Volatile call without timeout

**Detects:** a call to Tesla / Req / Finch / HTTPoison without an explicit timeout option, OR `GenServer.call/2` without a third-arg timeout (defaults to 5000ms — usually wrong for cross-process calls).

**The architectural cost:** unbounded waits create cascading failure scenarios. A slow downstream HTTP service eats the calling process's mailbox; a slow GenServer eats every caller's pool capacity; eventually the entire pipeline grinds to a halt — and the operator can't tell which downstream is the culprit because there's no timeout to surface as an error.

**Triggers (BAD):**

```elixir
defmodule MyApp.ExternalAPI do
  def fetch(url), do: Req.get!(url)        # no receive_timeout
end

defmodule MyApp.Worker do
  def get_state, do: GenServer.call(__MODULE__, :get)   # default 5000ms
end
```

**Doesn't trigger (GOOD):**

```elixir
defmodule MyApp.ExternalAPI do
  def fetch(url), do: Req.get!(url, receive_timeout: 10_000)
end

defmodule MyApp.Worker do
  def get_state, do: GenServer.call(__MODULE__, :get, 30_000)
end
```

##### CE-47 — Bang without non-bang sibling

**Detects:** a public `name!/n` function lacking a sibling `name/n` returning `{:ok, _} | {:error, _}`. The convention in Elixir is to ship pairs: `Repo.get/2` (returns `nil` or struct, never raises) and `Repo.get!/2` (returns struct or raises). When only the bang exists, callers wanting controlled error handling are forced into `try/rescue`.

**Triggers (BAD):**

```elixir
defmodule MyApp.Settings do
  def get!(key), do: Map.fetch!(:persistent_term, key)
  # No corresponding get/1 returning {:ok, value} | :error
end
```

**Doesn't trigger (GOOD — pair):**

```elixir
defmodule MyApp.Settings do
  def get(key) do
    case Map.fetch(:persistent_term, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

  def get!(key) do
    case get(key) do
      {:ok, value} -> value
      {:error, reason} -> raise "settings get! failed: #{reason}"
    end
  end
end
```

##### CE-49 — Catch-all rescue

**Detects:** see §3.2.4.

**The architectural cost:** every catch-all rescue is a bug suppressor. The intended exception (e.g., `Ecto.NoResultsError` from `Repo.get!/2`) gets caught alongside `MatchError` (typo), `ArithmeticError` (division by zero), `DBConnection.ConnectionError` (downstream is down), `KeyError` (missing field). The function returns the same `nil` for all of them, and the operator has no signal to investigate.

##### CE-54 — Low-possibility / high-value building-block

**Detects:** a function in the `:context` or `:schema` layer where:
- Substance score is high (`AST size ≥ 30`)
- At least one of `input_closure`, `determinism`, `totality`, `side_effect_free`, or `errors_as_values` failed (component score < 1.0)

**The architectural cost:** these are the functions doing real domain work that aren't structured for verification. They're the hardest to test (substance ≥ 0.7 means significant logic), the most consequential when changed (high value), AND they have at least one structural impurity blocking property tests.

**Why it's actionable:** the diagnostic names which component failed. If `side_effect_free` failed, the fix is to extract the side effect (CE-56 catches the easy version of this). If `input_closure` failed, the fix is to remove the `Application.get_env` from the function body and inject via parameter. If `errors_as_values` failed, the fix is to convert `raise` calls to `{:error, _}` returns.

##### CE-55 — Building-block function without property test

**Detects:** a function that already passes the building-block 6-component check (score ≥ 0.9, arity > 0) AND is not exercised by any `property "..." do ... end` block in test files.

**The architectural cost:** a function that's structurally pure, deterministic, total, and side-effect-free is the perfect candidate for property testing — the input domain can be generated, the output invariant asserted, and edge cases discovered automatically. Skipping property testing on these functions is leaving free verification on the table.

**Suggested fix per finding:**

```elixir
# In test/my_app/pricing_test.exs
use ExUnitProperties

property "discount/2 is monotonic in rate" do
  check all price <- positive_integer(),
            rate1 <- float(min: 0.0, max: 1.0),
            rate2 <- float(min: rate1, max: 1.0) do
    assert MyApp.Pricing.discount(price, rate2) <= MyApp.Pricing.discount(price, rate1)
  end
end
```

##### CE-56 — Effect leak in near-building-block

**Detects:** see §3.2.9 (where the marker is documented).

**Why it matters:** the function is one refactor away from a building block. The diagnostic specifically names the single side-effect call. The fix is mechanical (split into pure inner + thin wrapper) — much smaller than refactoring a multi-effect function.

##### CE-57 — Unguarded building block

**Detects:** see §3.1.6.

---

### 3.4 Architectural primitives — the shared modules behind the rules

Several rules share underlying analyzers. Understanding these primitives helps both when reading the rule code and when writing custom rules. Each primitive has a single-responsibility module, used by multiple rules and by `Archdo` itself.

#### 3.4.1 `Archdo.Phoenix` — file-layer classifier

**Module:** `lib/archdo/phoenix.ex`. **Tests:** `test/archdo/phoenix_test.exs`.

**Purpose:** classify each file into one of these layers based on path + AST inspection:

```
:application_root | :web | :live_view | :component | :controller |
:router | :context | :schema | :migration | :operational |
:test | :other
```

**Detection logic:**

| Layer | Signal |
|-------|--------|
| `:application_root` | File ends in `application.ex` OR module uses `use Application` |
| `:web` | File path under `_web/` or `web/` (excluding more specific layers) |
| `:live_view` | Module uses `use Phoenix.LiveView` OR `use AppWeb, :live_view` |
| `:component` | Module uses `use Phoenix.Component` OR `use AppWeb, :component` |
| `:controller` | Module uses `use Phoenix.Controller` OR `use AppWeb, :controller` |
| `:router` | Module uses `use Phoenix.Router` |
| `:operational` | Module uses `use Mix.Task`, file under `lib/mix/tasks/`, or path matches `data_migration/`, `release.ex`, `priv/repo/seeds*` |
| `:migration` | Module uses `use Ecto.Migration` |
| `:schema` | Module uses `use Ecto.Schema` |
| `:test` | Path under `test/` |
| `:context` | None of the above, in `lib/<app>/<context>.ex` shape |
| `:other` | Fallback |

**Used by:** rule 1.6 (Cross-cutting in domain), 1.9 (Time injection), 4.4 (External deps without behaviour), 4.18 (Unbounded external call), 4.19 (Missing telemetry), 5.30 (Process sleep), 5.24 (Dynamic atom name), 1.30 (Direct process call), 1.32 (Cross-context config), 4.5 (Import breadth), 1.31 (Shared DB table), 1.33 (Shared ETS table), 3.3 (Lib config via args), 4.20 (Unprotected external call), 7.25 (Untested module), 6.10 (Raise in non-bang), 1.26 (Reverse dependency), and others.

**Helper functions:**

```elixir
Archdo.Phoenix.classify_file(file_path, ast) :: %{layer: layer(), uses: [...], embed_templates: ...}
Archdo.Phoenix.operational?(classification) :: boolean()
```

**Override mechanism:** `.archdo.exs` doesn't currently expose layer overrides — the classifier is convention-driven and projects with non-standard layouts may need to map paths via `layers:` regex. For per-file overrides, the relevant rule must be marked or skipped via `# archdo:allow RULE_ID` comment suppression on the line.

**Why it's a primitive:** layer classification was scattered across 8 rules with hand-rolled `web_file?`, `controller_file?`, etc. helpers, each with subtle differences. Centralizing in `Phoenix.classify_file/2` means a project's layer classification is consistent across rules, and a layer-detection bug fix lands in one place.

#### 3.4.2 `Archdo.Volatility` — dependency-stability classifier

**Module:** `lib/archdo/volatility.ex`. **Tests:** `test/archdo/volatility_test.exs`.

**Purpose:** tag each module as `:stable`, `:volatile`, or `:mixed` based on the modules it depends on. The rules in pack `core` that consume volatility (CE-1, CE-2, CE-3, CE-4, CE-34, CE-35) use this classification to focus on cost-of-change-driving boundaries.

**The shipped per-dependency profile (~25 entries):**

| Module pattern | Tag |
|---------------|-----|
| `Tesla`, `Req`, `Finch`, `HTTPoison` | `:volatile` (network primitives) |
| `Ecto.Repo`, `Ecto.Multi`, `Ecto.Query` | `:stable` (Ecto API contract) |
| `Logger`, `:telemetry` | `:stable` (observability primitives) |
| `Phoenix.PubSub` | `:stable` (PubSub interface) |
| `DateTime`, `Date`, `Time`, `NaiveDateTime` | `:mixed` (volatile in some uses, stable in others — see dual-purpose resolution below) |
| `:inet`, `:gen_tcp`, `:gen_udp` | `:volatile` (network) |
| `:calendar` | `:stable` |
| `String`, `Enum`, `Map`, `Keyword`, `List`, `Stream` | `:stable` (BIF-equivalent) |

**Dual-purpose resolution:** `DateTime.utc_now/0` is volatile (changes every call); `DateTime.add/3` is stable (pure transformation). The volatility classifier resolves these per-call-site by checking the function name against a per-module profile — `:utc_now` is volatile, `:add` is stable.

**Density thresholds:** a module's volatility tag is computed from the ratio of volatile vs stable calls in its body:
- `volatile_ratio ≥ 0.40` → `:volatile`
- `volatile_ratio in 0.05..0.40` → `:mixed`
- `volatile_ratio < 0.05` → `:stable`

**Path overrides via `.archdo.exs`:**

```elixir
[
  volatile_paths: ["lib/my_app/external/", "lib/my_app/integrations/"],
  stable_paths: ["lib/my_app/core/"],
  dependency_volatility: [
    {MyApp.LegacyHTTP, :volatile},
    {MyApp.PureCore, :stable}
  ]
]
```

**Per-module override via marker:** `@archdo_volatility :stable | :volatile | :mixed`. See §3.2.18.

**Entry-point exemption.** Modules that use `Mix.Task` or `Application` are recognized as canonical entry-point boundaries — their job IS to bridge CLI / config / supervised processes to the outside world. The classifier short-circuits to `:stable` for these (override = `:entry_point`) before any call-density analysis runs. Pushing their `File.read!/1`, `System.cmd/3`, `File.cwd!/0` calls behind a behaviour just moves the volatility one module deeper, where the new module would be flagged identically. The exemption sits **below** author override and path override — `@archdo_volatility :volatile` on a Mix task still wins.

**Used by:** CE-1, CE-2, CE-3, CE-4, CE-34, CE-35.

#### 3.4.3 `Archdo.Blackbox` — building-block scorer

> **Naming note:** the module is `Archdo.Blackbox` for legacy reasons. Conceptually it scores *building-blocks* — code we own and can see inside that nonetheless composes as cleanly as if it were opaque. A true black box (code we cannot see inside) shouldn't exist in our own codebase.

**Module:** `lib/archdo/blackbox.ex`. **Tests:** `test/archdo/blackbox_test.exs`.

**Purpose:** score every public function on six independent components, multiplied together. A perfect score (1.0) means the function has every property property-based testing requires.

**The six components (each scored 0.0–1.0):**

| Component | What it measures | Component fails if... |
|-----------|------------------|----------------------|
| `input_closure` | Does the function read state outside its parameter list? | calls `Application.get_env`, `Process.get`, `:persistent_term.get`, `:ets.lookup`, `:ets.tab2list` |
| `determinism` | Is the output a function of inputs only? | calls `DateTime.utc_now`, `:rand.uniform`, `:erlang.system_time`, `:os.timestamp`, etc. |
| `output_completeness` | Is the return type documented? | no `@spec` for the function |
| `totality` | Does the function handle every possible input? | no catch-all clause AND no all-specific patterns covering the type |
| `side_effect_free` | Does the function avoid side effects? | calls `Logger.*`, `Phoenix.PubSub.broadcast`, `Repo.{insert,update,delete}`, `:telemetry.execute` |
| `errors_as_values` | Does the function return errors as values, not exceptions? | body contains `raise` |

**Class verdict:** `score_module/1` returns a list of `{name, arity, score, components}` per public function. `classify/1` maps the multiplied score to a class:

| Score | Class | Meaning |
|-------|-------|---------|
| ≥ 0.9 | `:building_block` | Property-testable, drop-in replaceable |
| ≥ 0.5 | `:near_block` | One or two structural fixes from `:building_block` |
| ≥ 0.2 | `:mixed` | Substantial structural impurities |
| < 0.2 | `:boundary` | Pure boundary (controller, GenServer callback, etc.) |

**Module verdict (M-Plan6 enhancement):** `module_verdict/1` combines:
1. Structural check: every public fn ≥ 0.9 on the 6-component score
2. Input-safety check: every public fn (arity > 0) constrains its input via `Archdo.InputGuard`

Returns `:building_block` or `{:leaks_at, [{name, arity, leak_reason}]}` where `leak_reason :: float() | :unguarded_input`.

**Boundary suggestion (M-Aux5):** `boundary_suggestion/1` decides whether a near-block module would benefit from extracting its pure functions into a sibling module. Returns:

```elixir
:building_block                                      # No extraction needed
| {:extract, leaky_fns, pure_fns}                    # Pure fns can be extracted
| {:refactor_in_place, %{component => fail_count}}   # Fix in place
```

**CLI:** `mix archdo --building-blocks` prints two sections:
1. Building-block MODULES (all public fns pass both checks)
2. Building-block CONTEXTS (all modules in the context's namespace are building blocks)

Plus a third section (M-Aux5): top-20 near-block modules ranked by refactor distance, each with its boundary suggestion.

**Used by:** CE-54, CE-55, CE-56, CE-57, plus the `--building-blocks` CLI command.

#### 3.4.4 `Archdo.AnchorSet` — reachability anchor discovery

**Module:** `lib/archdo/anchor_set.ex`. **Tests:** `test/archdo/anchor_set_test.exs`.

**Purpose:** compute the set of "anchored" modules — modules with externally-justified existence. CE-30 (unanchored module) and CE-31 (unanchored island) report modules NOT transitively reachable from this set.

**Anchor sources:**

| Source | What counts |
|--------|-------------|
| `use Mix.Task` | Mix task entry point |
| `use Application` | Application lifecycle callback |
| `use Phoenix.Router` | Phoenix router (HTTP route table) |
| `use Phoenix.LiveView` | Phoenix LiveView (route-mounted) |
| `use Oban.Worker` | Oban worker (queue-driven) |
| `use Phoenix.Channel` | Phoenix channel (websocket route) |
| `use Supervisor` | Nested supervisor (M-Plan8b) |
| `use DynamicSupervisor` | Dynamic supervisor (M-Plan8b) |
| `@archdo_anchor "reason"` | Explicit user-declared anchor |
| Children of any supervisor module | Listed in any `init/1` child list (M-Plan8b enhancement) |
| `Phoenix.classify_file` returning `:application_root`, `:controller`, `:live_view`, `:component`, `:router`, `:operational`, `:migration` | Layer-classified anchor |

**Closure walk:** `closure(anchors, graph)` walks the dependency graph forward from each anchor, collecting every module transitively reachable. The walker uses ALL edge types (`:alias`, `:import`, `:use`, `:call`, `:registry`, `:dynamic_dispatch`).

**M-Plan8a contribution:** the `:dynamic_dispatch` edge from `apply(LiteralModule, :fn, args)` is now part of the closure, capturing modules referenced only via runtime dispatch with literal targets.

**M-Plan8b contribution:** previously the children-of-supervisor anchor only fired for `use Application` modules. Now any nested `use Supervisor` / `use DynamicSupervisor` module is itself an anchor, AND its children (extracted from `init/1` child lists) are anchors.

**Field impact:** the May 2026 enhancements reduced Archdo's own self-analysis CE-30 false positives substantially. The remaining hits should be examined — they're either real dead code OR truly invisible dispatch shapes (registry maps consumed via `Application.get_env`, `:erpc` calls to other nodes) that need an `@archdo_anchor` marker.

**Used by:** CE-30, CE-31.

#### 3.4.5 `Archdo.InputGuard` — clause-constraint analyzer

**Module:** `lib/archdo/input_guard.ex` (new in M-Plan6). **Tests:** indirectly via CE-57 + Blackbox test suites.

**Purpose:** the single source of truth for "is this function clause's input domain constrained?" Used by CE-57 (UnguardedBuildingBlock) and `Blackbox.module_verdict/1`.

**Definition of "constrained":** a clause is constrained when AT LEAST ONE of:
- The head has a `when` guard
- All argument patterns are specific (no bare-variable args)
- The body's last expression is an `{:error, _}` literal (clause is the explicit error fallback)

A function is well-guarded when EVERY clause is constrained. CE-57 and the building-block analysis (`Archdo.Blackbox`) both fire when ANY clause is unconstrained.

**API:**

```elixir
Archdo.InputGuard.collect_clauses(ast) :: %{{atom(), arity()} => [clause]}
# Each clause: %{args, guard?, body, meta}

Archdo.InputGuard.any_unconstrained?(clauses) :: boolean()
```

**Why it exists as a separate module:** CE-57 implemented the clause walker first (M-Aux6). M-Plan6 needed the same logic for module-level verdict in Blackbox. Rather than duplicate ~30 lines of clause analysis, the predicates were extracted to `InputGuard`. Future rules wanting the same constraint check can use the same primitive.

**Used by:** CE-57, `Archdo.Blackbox.module_verdict/1`.

#### 3.4.6 `Archdo.IrreversibleDecision` — schema/supervisor/public-API classifier

**Module:** `lib/archdo/irreversible_decision.ex`. **Tests:** indirectly via CE-11/CE-12 test suites.

**Purpose:** identify modules that represent irreversible decisions — schemas (data contracts), supervisors (process tree), or public-API modules (consumer contracts). These modules carry higher contract obligations because changing them breaks consumers in ways non-irreversible modules don't.

**Detection:**

| Module type | Signal |
|------------|--------|
| Ecto schema | `use Ecto.Schema` |
| Supervisor | `use Supervisor`, `use DynamicSupervisor`, OR defines `child_spec/1` |
| Public API | File path matches a `.archdo.exs` `public_api_paths` regex |
| Oban worker | `use Oban.Worker` (also classified as anchor) |

**API:**

```elixir
Archdo.IrreversibleDecision.candidate?(file, ast, opts) :: boolean()
Archdo.IrreversibleDecision.oban_worker?(ast) :: boolean()
```

**Used by:** CE-11 (contract density), CE-12 (public API spec coverage). CE-12 is the focused subset of CE-11 — fires when spec coverage is below 80% on a candidate module, regardless of cohort comparison.

#### 3.4.7 `Archdo.PiiSchema` — PII field detection

**Module:** `lib/archdo/pii_schema.ex`. **Tests:** indirectly via CE-51/CE-53 test suites.

**Purpose:** identify Ecto schemas containing PII-shaped fields. Used by CE-51 (PII field without designated handling) and CE-53 (PII schema without right-to-deletion path).

**Default field name patterns:**

| Pattern | Match |
|---------|-------|
| Exact match | `email`, `phone`, `ssn`, `address`, `dob`, `date_of_birth`, `national_id`, `tax_id` |
| Prefix match | `password*` (e.g., `password`, `password_hash`, `password_reset_token`), `passport*` |
| Suffix match | `*_token` (e.g., `auth_token`, `reset_token`, `verification_token`) |

**API:**

```elixir
Archdo.PiiSchema.has_pii_fields?(ast) :: boolean()
Archdo.PiiSchema.pii_field_names(ast) :: [atom()]
```

**Used by:** CE-51, CE-53.

**Customization:** the field name patterns are currently hard-coded. A future enhancement would expose `.archdo.exs` `pii_field_patterns:` for project-specific PII shapes (e.g., `customer_id` in some healthcare contexts).

#### 3.4.8 `Archdo.Graph` and `Archdo.Compiled.Graph` — dependency graphs

**Modules:** `lib/archdo/graph.ex` (static, AST-derived) and `lib/archdo/compiled/graph.ex` (BEAM-traced, compile-time captured).

**The two graphs differ in source AND content:**

| Aspect | `Archdo.Graph` (static) | `Archdo.Compiled.Graph` (compiled) |
|--------|-------------------------|-----------------------------------|
| Source | `lib/**/*.ex` AST parse | BEAM files + compilation tracer |
| When built | Every `mix archdo` run | Only with `--compiled` flag |
| Captures | `alias`, `import`, `use`, qualified remote calls (with short-form alias-table resolution), multi-alias `Foo.{Bar, Baz}`, `apply/3` with literal target, registry attribute lists, `defdelegate ..., to: SomeModule`, `__MODULE__.Sub` references, `%Foo.Bar{...}` struct construction, nested-defmodule scope-restored | Every resolved remote call (even via macro expansion), import resolution, protocol dispatch targets, `@optional_callbacks` |
| Misses | Dynamic dispatch (`apply(var, :fn, args)`), macro-expanded calls invented at compile time, runtime configuration dispatch (`Code.put_compiler_option(:tracers, [...])`), named processes located via `Process.whereis/1` — escape via `@archdo_anchor` | Nothing — captures the resolved truth |
| Performance | Fast (~1s for 100K LOC) | Slower (requires recompile + tracer collection) |

**Edge types in `Archdo.Graph`:**

```
:alias              # `alias MyApp.Foo` / `alias MyApp.{A, B}` / `alias MyApp.Foo, as: Bar`
:import             # `import MyApp.Foo`
:use                # `use MyApp.Foo`
:call               # `MyApp.Foo.bar(...)` qualified remote call (incl. short-form
                    #   resolved through the alias table), `defdelegate ..., to: Mod`,
                    #   `%Foo.Bar{...}` struct construction, `__MODULE__.Sub` references
:registry           # @attr [Foo, Bar] consumed via Enum.* / for / Stream.*
:dynamic_dispatch   # apply(LiteralMod, :fn, args)
```

**Alias-table resolution (M-CG44).** Every `defmodule` opens a fresh
alias-table scope; `alias Foo.Bar` records `:Bar => "Foo.Bar"`,
`alias MyApp.{Runner, Rules}` records both. Subsequent short-form
references like `Runner.start()` resolve through the table to
`MyApp.Runner` instead of producing a dangling edge to bare `"Runner"`.
Without this, every `alias`-then-call pattern in the codebase produced
edges that the closure walk couldn't traverse — the dominant cause of
CE-30 false positives before M-CG44.

**Nested-defmodule scope (M-CG46).** The extractor uses `Macro.traverse/4`
with a module-scope **stack** instead of `Macro.prewalk/2`. Pre-visitor
pushes `{module, alias_table}` on `defmodule` enter; post-visitor pops
on exit, restoring outer state. Without this, code following a nested
`defmodule Inner do` in the parent's body was misattributed to `Inner`,
breaking outgoing-edge tracking.

**API:**

```elixir
Archdo.Graph.build(file_asts) :: %Archdo.Graph{}
Archdo.Graph.dependencies(graph, module) :: [edge()]   # what does `module` depend on?
Archdo.Graph.dependents(graph, module) :: [edge()]     # what depends on `module`?
```

**`Archdo.Compiled.Graph`** has a richer API for BEAM-derived analysis:

```elixir
Archdo.Compiled.Graph.callers(graph, mfa)          # who calls this function?
Archdo.Compiled.Graph.find_function(graph, mfa)    # locate function metadata
Archdo.Compiled.Graph.unused_functions(graph)      # exported but uncalled
Archdo.Compiled.Graph.find_recursive_calls(graph, mfa)  # self-loops
# ... and ~15 more
```

**Used by:**
- `Archdo.Graph` → CE-30, CE-31 (via `AnchorSet.closure/2`), and any rule needing module-level dependency information
- `Archdo.Compiled.Graph` → all 21 compiled-analysis rules in `Archdo.Rules.Compiled.*`

**Future split (deferred):** `Archdo.Compiled.Graph` is currently 927 lines mixing build (struct + ingest) and read (query API) responsibilities. A deferred refactor splits it into `Compiled.Graph` (build) + `Compiled.Query` (read), with `Archdo.Compiled` as the public facade.

#### 3.4.9 `Archdo.Quadrant` — 2-axis policy primitive (two-dimensional architectural tests)

**Module:** `lib/archdo/quadrant.ex`. **Tests:** `test/archdo/quadrant_test.exs`.

**Purpose:** the rule infrastructure for tests whose finding semantics depend on the **cross-product of two architectural axes**, not on a single threshold. A traditional rule answers "does this module exceed a threshold?" — yes/no, one axis. A quadrant rule answers "given THIS structural property combined with THAT classification, is the combination problematic?" — a 2D cell lookup against a policy table.

The canonical example is the volatility-substitutability quadrant (CE-2/CE-3): abstraction density × volatility tag. A `:volatile` module without abstraction is a missing seam at the boundary (CE-2 fires); a `:stable` module heavily abstracted is over-engineered stable code (CE-3 fires); the other two cells (`:volatile + :high_abstraction` and `:stable + :low_abstraction`) are correct shapes and don't fire.

**The behaviour contract:**

```elixir
defmodule Archdo.Rules.CE.MyQuadrantRule do
  @behaviour Archdo.Rule
  @behaviour Archdo.Quadrant

  # axes/3: per-file analysis returning [{cell, evidence}, ...]
  # The cell is a 2-tuple; one entry per analyzed unit (module / function / call).
  @impl Archdo.Quadrant
  def axes(file, ast, opts), do: ...

  # policy/0: %{cell => action} where action is :no_finding | {:fire, severity, rule_id, title}.
  # Cells absent from the map default to :no_finding.
  @impl Archdo.Quadrant
  def policy, do: %{
    {:high, :volatile} -> :no_finding,           # earned abstraction
    {:low, :volatile}  -> {:fire, :info, "CE-2", "Volatile boundary lacks abstraction"},
    {:high, :stable}   -> {:fire, :info, "CE-3", "Stable core with abstraction overhead"},
    {:low, :stable}    -> :no_finding            # simplicity is correct
  }

  # finding_for/4: build a Diagnostic for an actionable cell.
  @impl Archdo.Quadrant
  def finding_for(cell, fire_action, evidence, file), do: %Archdo.Diagnostic{...}
end
```

**Mechanics:** `Archdo.Quadrant.evaluate/4` walks the rule's axes output, looks up each cell in the policy, and invokes `finding_for/4` for `:fire` cells. Cells absent from the policy are silently `:no_finding` — the policy table is the single source of truth for which combinations are actionable.

**Why a separate primitive instead of nested `case` inside `analyze/3`:**

1. **Policy is data, not control flow.** A `Map`-based policy is easier to read, easier to extend (add a cell, no rewrite), and easier to test (assert the policy directly, no need to construct ASTs that hit each branch).
2. **Distribution reporting.** `Archdo.Quadrant.distribution_for/4` returns a `%{cell => count}` map without invoking `finding_for/4` — used by `--metrics` to show the quadrant occupancy table without firing diagnostics.
3. **List-rules accessor.** `Archdo.Quadrant.list_rules(rules)` filters a rule list down to those implementing the Quadrant behaviour. `--metrics` and the report formatter use it to discover which rules contribute to the cross-product table.

**Quadrant rules in the registry (Nov 2026):**

| Rule | Axes | Policy |
|------|------|--------|
| **CE-2/CE-3** Volatility-substitutability | `{abstraction_class, volatility_tag}` ∈ `{:high, :low} × {:volatile, :stable, :mixed}` | `:low × :volatile` → CE-2 fire (missing seam at boundary). `:high × :stable` → CE-3 fire (over-engineered stable core). `:high × :volatile` and `:low × :stable` → `:no_finding` |
| **CE-24** Complexity shape | `{cyclomatic_band, cognitive_band}` ∈ `{:low, :high} × {:low, :high}` | `:high × :high` → fire `CE-24-twisty` (nested + many branches). `:high × :low` → fire `CE-24-flat-dispatch` (many clauses, each shallow — 6.2 over-counting). `:low × :high` → fire `CE-24-deeply-nested-simple-dispatch`. `:low × :low` → `:no_finding` |
| **CE-54** Building-block quadrant | `{possibility, value}` ∈ `{:high, :low} × {:high, :low}` | `:low × :high` → fire (low-possibility / high-value: hardest to test, most consequential when changed). Other cells emit either `:no_finding` or paired CE-55/CE-56/CE-57 findings |

**Why this is more than three independent rules:** the quadrant pattern explicitly encodes that the diagnostic depends on a *combination* of classifications, not on each axis separately. Treating CE-2 as "fire when low abstraction" would over-fire on simple stable modules where low abstraction is correct. Treating CE-24 as "fire when cyclomatic high" over-fires on flat-dispatch tables where the shape is benign. The policy table makes the combinatorial truth explicit and reviewable.

**Used by:** CE-2/CE-3 (volatility-substitutability), CE-24 (complexity shape), CE-54 (building-block quadrant).

---

## 4. The diagnostic shape

Every Archdo finding is an `%Archdo.Diagnostic{}` struct. The shape is the contract — formatters and the MCP server serialize this directly. The fields are:

```elixir
%Archdo.Diagnostic{
  rule_id: "8.2",                      # canonical id (matches ARCHITECTURE_RULES.md)
  severity: :error,                    # :error | :warning | :info
  title: "Side effect in aggregate apply/2",
  message: "Error.apply/2 calls Logger.error inside an event handler clause",
  why:
    "apply/2 is invoked on every event during aggregate rehydration, not just " <>
    "when the event is first emitted. Side effects there fire N times per " <>
    "process restart, spam observability tooling, and can re-trigger external " <>
    "systems (emails, webhooks, alerts) on every replay.",
  alternatives: [
    %Archdo.Fix{
      summary: "Move the side effect to the command handler (execute/2)",
      detail:
        "execute/2 runs exactly once per command, before any event is " <>
        "persisted. Emit the log or external call there. apply/2 should be " <>
        "a pure function from (state, event) to new state.",
      example: "```elixir\n# apply/2 stays pure ...\n```\n",
      applies_when: "The side effect should fire when the command is processed, not on replay."
    },
    %Archdo.Fix{
      summary: "Move the side effect to a process manager subscribed to the event",
      detail: "Process managers react to persisted events asynchronously...",
      example: nil,
      applies_when: "The side effect needs to coordinate with other aggregates or external systems."
    }
  ],
  references: [
    "ARCHITECTURE_RULES.md#8.2",
    "https://hexdocs.pm/commanded/Commanded.Aggregate.html"
  ],
  context: %{
    module: "Error",
    function: "apply/2",
    side_effect: "Logger.error",
    line: 87
  },
  file: "lib/errors/error_aggregate.ex",
  line: 87
}
```

### Field semantics — the contract

| Field                         | Audience       | Style                                                              | Length          |
|-------------------------------|----------------|---------------------------------------------------------------------|-----------------|
| `rule_id`                     | both           | Stable identifier matching `ARCHITECTURE_RULES.md`                  | "X.Y" string    |
| `severity`                    | both           | `:error` / `:warning` / `:info`                                     | atom            |
| `title`                       | both           | Noun phrase, no verb                                                | 3–8 words       |
| `message`                     | both           | Past-tense factual: "X calls Y", "module Z has N functions"         | 1 sentence      |
| `why`                         | LLM primarily  | Explains the architectural consequence. **No prescriptions.**       | 1–3 sentences   |
| `alternatives[].summary`      | both           | Imperative: "Move the side effect to..."                            | 1 sentence      |
| `alternatives[].detail`       | LLM primarily  | How to apply the fix; when this option fits                          | 2–5 sentences   |
| `alternatives[].example`      | LLM primarily  | Optional markdown code block (before/after)                         | ≤ 20 lines      |
| `alternatives[].applies_when` | LLM primarily  | "Use this fix when…" — disambiguates between options                | 1 sentence      |
| `references`                  | both           | Anchors like `"ARCHITECTURE_RULES.md#8.2"`, doc URLs                | list of strings |
| `context`                     | LLM primarily  | Rule-specific structured detail (module names, line numbers, counts, cycles, etc.) | map             |
| `file`                        | both           | Project-relative path                                               | string          |
| `line`                        | both           | 1-based line number, or 0 if file-level                              | integer         |

### Why the shape is structured this way

- **`title` is stable.** When you want to test "did this rule fire", assert on `title` and `rule_id`. `message` is parameterized by the source under analysis and changes between projects.
- **`message` is factual, not prescriptive.** It says what was found, not what to do. The "what to do" lives in `alternatives`.
- **`why` is detached from `message`.** The same rule fires for many different code shapes; the `why` text explains the underlying architectural principle once, the `message` describes the specific instance.
- **`alternatives` are ranked.** The first fix is the canonical answer. Subsequent fixes cover edge cases. For false-positive-prone rules, the first fix is "verify this is real" (e.g. checking that a flagged schema construction isn't in a fixture).
- **`context` is for tools.** It carries structured data the rule already computed (cycle paths, function names, counts) so a downstream consumer doesn't have to re-parse the message.

---

## 5. Output formats

`mix archdo --format <format>` accepts seven formats. All are driven by `Archdo.Formatter` and consume the same `Diagnostic` struct.

### `:summary` (default) — overview table

Markdown pipe table grouped by rule, sorted by severity then count. Shows a `Tag` column when performance rules are present:

```
Archdo — 225 findings (0 errors, 26 warnings, 199 info)

| Sev     | Rule  | Count | Tag  | Finding |
|---------|-------|------:|------|---------|
| warn    | 3.1   |    17 |      | Structurally identical function clone |
| warn    | 6.50  |     3 | perf | List ++ in loop accumulator |
| info    | 6.41  |    23 |      | Single-clause with |
| info    | 6.53  |     1 | perf | Keyword lookup inside loop |

225 total across 39 rules
```

### `:text` — for humans at the terminal

Color-coded, grouped by category, full `why` and `alternatives` for each finding:

```
Archdo — Architectural Quality Check

Event Sourcing
  error   [8.2] Side effect in aggregate apply/2
         Error.apply/2 calls Logger.error inside an event handler clause
         in lib/errors/error_aggregate.ex:87
         why: apply/2 is invoked on every event during aggregate rehydration,
         why: not just when the event is first emitted. Side effects there fire
         why: N times per process restart, spam observability tooling, and can
         why: re-trigger external systems (emails, webhooks, alerts) on every replay.
         fixes:
           1. Move the side effect to the command handler (execute/2)
              execute/2 runs exactly once per command, before any event is
              persisted. Emit the log or external call there. apply/2 should
              be a pure function from (state, event) to new state.
              when: The side effect should fire when the command is processed, not on replay.
           2. Move the side effect to a process manager subscribed to the event
              Process managers react to persisted events asynchronously...
              when: The side effect needs to coordinate with other aggregates or external systems.

Found 1 errors, 0 warnings, 0 info.
```

### `:compact` — for grep/sed

One line per finding, filename and line number first:

```
lib/errors/error_aggregate.ex:87: error [8.2] Side effect in aggregate apply/2 — Error.apply/2 calls Logger.error inside an event handler clause
```

Use this for navigation, log aggregation, or piping into editor quickfix lists.

### `:json` — for CI dashboards

Pretty-printed JSON with a `summary` envelope. The whole `Diagnostic` shape (including `alternatives`, `context`, `references`) is preserved:

```json
{
  "summary": {"errors": 1, "warnings": 0, "infos": 0, "total": 1},
  "diagnostics": [
    {
      "rule_id": "8.2",
      "severity": "error",
      "title": "Side effect in aggregate apply/2",
      "message": "Error.apply/2 calls Logger.error inside an event handler clause",
      "why": "...",
      "alternatives": [{"summary": "...", "detail": "...", "example": "...", "applies_when": "..."}],
      "references": ["ARCHITECTURE_RULES.md#8.2", "..."],
      "context": {"function": "apply/2", "side_effect": "Logger.error", ...},
      "file": "lib/errors/error_aggregate.ex",
      "line": 87
    }
  ]
}
```

### `:llm` — for streaming consumption by LLM clients

Newline-delimited JSON (NDJSON), one diagnostic per line. The first line is a `{"type": "summary", ...}` envelope so consumers can short-circuit. Each subsequent line is the full `Diagnostic` map plus a `markdown` field with a pre-rendered, LLM-friendly markdown block:

```
{"type":"summary","errors":1,"warnings":0,"infos":0,"total":1}
{"type":"diagnostic","rule_id":"8.2","severity":"error","title":"Side effect in aggregate apply/2", ... ,"markdown":"### [8.2] Side effect in aggregate apply/2\n\n**Severity:** error  \n**Location:** `lib/errors/error_aggregate.ex:87`\n\n**Finding:** Error.apply/2 ...\n\n**Why it matters:** apply/2 is invoked on every event ...\n\n**Fix options:**\n\n1. **Move the side effect to the command handler (execute/2)**\n   execute/2 runs exactly once ..."}
```

The pre-rendered `markdown` field is the easiest path for an LLM that just wants a single string to display or reason about.

### `:sarif` — for GitHub Code Scanning

SARIF 2.1.0 format that integrates with GitHub's code scanning feature. Upload the output to show Archdo findings inline on pull requests:

```bash
mix archdo --format sarif > archdo.sarif
# Upload to GitHub via Actions: uses: github/codeql-action/upload-sarif@v3
```

### `:html` — standalone report

Generates a dark-themed HTML file (`archdo_report.html`) with a summary table and expandable details. Share with stakeholders who don't have terminal access:

```bash
mix archdo --format html --paths lib
# Opens archdo_report.html in a browser
```

### Exit codes (all formats)

| Findings present  | Exit code |
|-------------------|-----------|
| Errors            | 2         |
| Warnings (no errors) | 1      |
| Info only / clean | 0         |

This is so CI can use `mix archdo` directly without parsing output.

---

## 6. CLI reference

```
mix archdo [options]
```

| Option            | Type            | Description                                                                                |
|-------------------|-----------------|--------------------------------------------------------------------------------------------|
| `--paths`         | comma-separated | Paths to scan. Default: `lib`. Accepts directories or single files.                        |
| `--format`        | enum            | `summary` (default) / `text` / `compact` / `json` / `llm` / `sarif` / `html`              |
| `--only`          | comma-separated | Restrict the run to these rule ids: `--only 5.11,8.2`                                      |
| `--ignore`        | comma-separated | Skip these rule ids: `--ignore 6.1,6.4`                                                    |
| `--since`         | git ref         | Only analyze files changed since this ref: `--since main`, `--since HEAD~3`                |
| `--explain`       | rule id         | Print rule description and category: `--explain 6.50`                                      |
| `--init`          | flag            | Generate a `.archdo.exs` config file with detected project defaults                        |
| `--fix`           | flag            | Auto-apply mechanical fixes (currently: unused alias removal)                               |
| `--watch`         | flag            | Re-run analysis on file changes (2s poll). Ctrl+C to stop.                                 |
| `--boundaries`    | flag            | Cross-file boundary/graph rules. **Default: true.** Disable with `--no-boundaries`.        |
| `--tests`         | flag            | Project-level test architecture rules. Default: false.                                     |
| `--functions`     | flag            | Function-level graph analysis. **Default: true.** Disable with `--no-functions`.            |
| `--compiled`      | flag            | Read compiled beam files for ground-truth analysis (dead code, blast radius, cycles).      |
| `--diagram`       | type            | Generate Mermaid diagram: `overview`, `modules`, `api`, `context:Name`, `blast:Module`.    |
| `--coverage`      | flag            | Print test coverage gap matrix and exit.                                                   |
| `--metrics`       | flag            | Print Martin package metrics (Ca/Ce/I/A/D) matrix and exit.                                |
| `--freeze`        | flag            | Save current findings as the baseline.                                                     |
| `--freeze-stats`  | flag            | Show baseline status (resolved, still present, new).                                       |
| `--show-all`      | flag            | Bypass the baseline filter and show every finding.                                         |

### Common invocations

```bash
# Full check — boundaries + functions enabled by default
mix archdo

# Add test architecture and compiled beam analysis
mix archdo --tests --compiled

# Fast check — skip boundary and function graph analysis
mix archdo --no-boundaries --no-functions

# PR review — only check changed files
mix archdo --since main

# Performance audit only
mix archdo --only 6.46,6.47,6.48,6.49,6.50,6.51,6.52,6.53

# Restrict to one rule
mix archdo --only 8.2 --paths lib

# Skip noise
mix archdo --ignore 6.1,6.4,7.25

# Auto-fix what's mechanical
mix archdo --fix

# Watch mode (re-runs on save)
mix archdo --watch

# Explain a rule
mix archdo --explain 6.50

# Generate config
mix archdo --init
```

### Output for different audiences

```bash
# Terminal review with full explanations
mix archdo --format text

# CI pipeline (exit code indicates severity)
mix archdo --format compact

# GitHub Code Scanning integration
mix archdo --format sarif > archdo.sarif

# Shareable HTML report
mix archdo --format html

# Dashboard/API consumption
mix archdo --format json > diagnostics.json

# LLM-friendly streaming
mix archdo --format llm > diagnostics.ndjson
```

### Special-purpose commands

```bash
mix archdo --coverage --paths lib    # Test coverage gap matrix
mix archdo --metrics --paths lib     # Martin Ca/Ce/I/A/D table
mix archdo --diagram overview        # Mermaid architecture diagram (requires --compiled)
mix archdo --diagram blast:MyApp.Accounts  # Blast radius for a module
```

---

## 7. Configuration (`.archdo.exs`)

Most projects work with **zero configuration** — Archdo detects Phoenix conventions from `mix.exs`. For non-Phoenix projects, umbrella apps, or custom layouts, drop a `.archdo.exs` file at the project root:

```elixir
# .archdo.exs
[
  # Layer regex patterns. Default convention assumes Phoenix:
  #   interface = MyAppWeb.*
  #   domain    = MyApp.* (excluding Repo/Mailer/Infrastructure)
  #   infrastructure = MyApp.{Repo,Mailer,Infrastructure}.*
  layers: [
    interface: ~r/^MyAppWeb\./,
    domain: ~r/^MyApp\.(?!Repo|Mailer|Infrastructure)/,
    infrastructure: ~r/^MyApp\.(Repo|Mailer|Infrastructure)/
  ],

  # Allowed dependency edges. Defaults are:
  #   interface → [domain, infrastructure]
  #   domain → [infrastructure]
  #   infrastructure → []
  allowed_deps: %{
    interface: [:domain, :infrastructure],
    domain: [:infrastructure],
    infrastructure: []
  },

  # Bounded contexts — each is a "context root module" that owns a subtree.
  # Used by rules 1.2, 1.7, 1.10 to detect cross-context internal access.
  contexts: [
    MyApp.Accounts,
    MyApp.Billing,
    MyApp.Catalog
  ],

  # Optional: regex matching adapter modules (excluded from some rules)
  adapters: ~r/\.(Adapters?|Impl|Client)\./,

  # Per-rule overrides (severity, thresholds)
  overrides: [
    {:"5.6", :ignore},                                  # accept default max_restarts
    {:"6.1", severity: :error, max_public_functions: 15}
  ],

  # Per-rule numeric threshold overrides — replaces hard-coded
  # rule defaults without forking the rule. Each entry is
  # {rule_id, [option: value, ...]}. The rule reads its threshold
  # via Archdo.Config.threshold/4 at analysis time.
  thresholds: [
    {"1.6", max_logger_calls: 5},     # default 3 — bump for logging-heavy domains
    {"1.11", min_files: 5}            # default 3 — bump if your contexts run small
  ]
]
```

### Configurable thresholds

The `thresholds:` keyword lets you tune per-rule numeric knobs without overriding severity. Currently wired:

| Rule | Key | Default | Effect |
|------|-----|---------|--------|
| **1.6** Cross-cutting in domain | `:max_logger_calls` | 3 | Maximum Logger calls per domain module before firing |
| **1.11** Anemic context | `:min_files` | 3 | A context directory with fewer files than this is "anemic" |

The shape extends naturally to other rules — they need to call `Archdo.Config.threshold(config, rule_id, key, default)` from their `analyze/3` (or `analyze_project/2`) callback. The runner threads the loaded `%Config{}` via `opts[:config]`. See `lib/archdo/rules/module/cross_cutting_in_domain.ex` and `lib/archdo/rules/boundary/anemic_context.ex` for the pattern.

### How layer detection actually works

`Archdo.Config` reads `mix.exs` to detect the app's name (e.g. `:my_app` → `MyApp`), then derives the default layer regexes from it. If `.archdo.exs` exists, its declarations override the defaults but `mix.exs` detection still runs to fill in the app/web module names.

**Convention with declaration override** is the principle. Convention works for the majority case; declaration handles the rest.

---

## 8. Freeze / baseline workflow

Adopting Archdo on an existing codebase typically surfaces hundreds of pre-existing issues. The freeze workflow lets you accept them as a baseline so only **new** violations show up going forward.

```bash
# 1. Capture the current state
mix archdo --freeze
# → Writes .archdo_baseline.exs with a fingerprint of every current finding.

# 2. Commit the baseline
git add .archdo_baseline.exs
git commit -m "archdo: baseline"

# 3. Day-to-day: only new findings appear
mix archdo
# → Pre-existing findings are filtered out; new violations show up.

# 4. See progress
mix archdo --freeze-stats
# →
#   Baseline fingerprints:  127
#   Still present:          103
#   Resolved (fixed):        24  ✓✓
#   New since baseline:       2  (small)
#   Current total:          105

# 5. Bypass the baseline temporarily
mix archdo --show-all
```

The fingerprint is `{rule_id, file, line}` plus a content hash, so adding/removing unrelated lines doesn't shift the baseline.

---

## 9. MCP server (for LLM clients)

Archdo ships an **MCP (Model Context Protocol) server** so LLM clients — Claude Code, Cursor, Cline, Zed, Codex — can call Archdo's analysis directly as a tool, no human intermediary needed.

```bash
mix archdo.mcp
```

The server speaks **newline-delimited JSON-RPC 2.0** over stdin/stdout (logs go to stderr). It runs in-process — no extra OS process — and reuses the same `Archdo.Runner` the CLI uses, so results are identical.

### The 12 tools

| Tool name              | Purpose                                                                       | Returns                                                |
|------------------------|-------------------------------------------------------------------------------|--------------------------------------------------------|
| `archdo_analyze_paths` | Run Archdo against directories or files                                      | `{summary, diagnostics: [...]}`                         |
| `archdo_analyze_file`  | Analyze an in-memory source string (no file write)                            | `{summary, diagnostics: [...]}`                         |
| `archdo_deep_review`   | Static analysis + structured review plan for deeper investigation            | `{diagnostics, review_plan: [...], instructions}`       |
| `archdo_list_rules`    | List rules (optionally filtered by category)                                  | `{count, rules: [{id, category, description, module}]}` |
| `archdo_explain_rule`  | Look up a rule by id                                                          | `{id, module, description, reference, note}`           |
| `archdo_health`        | Project health grade (A+ to D) + top rules + perf count                      | `{summary, top_rules, health_grade}`                    |
| `archdo_diff`          | Analyze only files changed since a git ref (PR review)                       | `{ref, changed_files, diagnostics}`                     |
| `archdo_diagram`       | Generate Mermaid/SVG architecture diagrams from compiled beams               | `{type, format, content}`                               |
| `archdo_perf_audit`    | Performance-only scan grouped by impact level                                 | `{total, by_impact, summary}`                           |
| `archdo_suggest`       | File-type-aware proactive suggestions (GenServer→OTP, LiveView→boundary)     | `{file_type, findings, suggestions}`                    |
| `archdo_explain_finding` | Given file:line, return finding with code context                           | `{finding, code_context}`                               |
| `archdo_fix`           | Generate executable edit suggestions for mechanical rules                     | `{fixable_count, fixes: [...]}`                         |

### Tool input schemas

#### `archdo_analyze_paths`

```jsonc
{
  "paths": ["lib", "test"],          // required: directories or files
  "only": ["5.11", "8.2"],           // optional: restrict to these rule ids
  "ignore": ["6.1"],                  // optional: skip these rule ids
  "min_severity": "warning",          // optional: "info" | "warning" | "error"
  "boundaries": true                  // optional: include cross-file rules. Default: true.
}
```

Returns the full structured `{summary, diagnostics}` shape described in [§4](#4-the-diagnostic-shape) and [§5](#5-output-formats).

#### `archdo_analyze_file`

```jsonc
{
  "file": "lib/my_app/account.ex",    // required: virtual path used for diagnostics
  "content": "defmodule ... end",     // required: Elixir source code
  "only": ["8.2"],                    // optional
  "ignore": []                        // optional
}
```

Use this when the LLM is about to write a file and wants to validate it before saving. Cross-file/graph rules (1.1, 1.3, 8.4) are skipped because they need the full project graph.

#### `archdo_list_rules`

```jsonc
{
  "category": "event_sourcing"        // optional: filter to one category
}
```

Categories: `boundaries`, `public_api`, `ssot`, `coupling`, `otp`, `module_quality`, `testing`, `event_sourcing`, `state_machine`, `composition`, `nif`.

#### `archdo_explain_rule`

```jsonc
{
  "id": "8.2"                         // required
}
```

#### `archdo_deep_review`

This is the **two-layer tool** — it combines Archdo's static analysis (Layer 1) with a structured review plan (Layer 2) that guides the LLM to investigate deeper architectural issues the AST checker cannot see.

```jsonc
{
  "paths": ["lib"],                    // required: directories or files
  "only": ["5.1", "5.17", "11.1"],     // optional: restrict static analysis
  "ignore": [],                         // optional
  "min_severity": "warning"             // optional
}
```

Returns three sections:

- **`diagnostics`** — the same `{summary, diagnostics}` as `archdo_analyze_paths`
- **`review_plan`** — a prioritized list of investigation items, each with:
  - `category` — what area to investigate (e.g. "Supervision Tree Architecture", "Resource Leak Risk", "Clone Semantic Mismatch")
  - `priority` — 1 = most critical, 6 = informational
  - `triggered_by` — which static finding(s) triggered this investigation
  - `files_to_read` — specific files the LLM should read
  - `questions` — concrete questions to answer by reading the source code
- **`instructions`** — tells the LLM how to use the review plan

**How the review plan is generated:**

The review plan maps static findings to deeper questions. Examples:

| Static finding | Review plan question |
|---|---|
| 5.1 (bare spawn) | "Read the spawned function body. Does it allocate OS resources? If it crashes, are those resources cleaned up?" |
| 5.20 (monitor without :DOWN) | "Does the module also send messages via Process.send_after that lack handlers? What state becomes stale when the monitored process dies?" |
| 3.1 (duplicated code) | "Read both copies. Do they compute the same thing? Look for subtle formula differences." |
| 11.1 (NIF without behaviour) | "Read the native source (.rs/.zig/.c). Are there global mutable variables? Does it allocate kernel resources?" |
| Multiple OTP findings | "Map the full supervision tree. Are there children started in multiple places? Does the restart strategy match the dependency relationships?" |

Plus three "always ask" categories that fire on every review: Domain Model Integrity, Error Handling Consistency, and Concurrency & Process Lifecycle.

**When to use `archdo_deep_review` vs `archdo_analyze_paths`:**

- Use `archdo_analyze_paths` for quick structural checks ("does this file have any issues?")
- Use `archdo_deep_review` when the user asks for a comprehensive architectural review, or when you want to find issues that require understanding the code's intent

### Configuring an MCP-aware client

The same `mcpServers` config works for Claude Code, Cursor, Cline, Zed, and Codex:

```jsonc
{
  "mcpServers": {
    "archdo": {
      "command": "mix",
      "args": ["archdo.mcp"]
    }
  }
}
```

**Project-local** — drop the file as `.mcp.json` in the Elixir project root. Claude Code and most other clients pick it up automatically when running in that directory.

**Global** — add the same entry under `~/.claude.json` (Claude Code) or the equivalent global config for your client. Add a `"cwd": "/absolute/path/to/elixir/project"` entry so the server boots in the right Mix environment.

Once the server is running, ask the LLM things like:

- *"Check the architecture of this project with archdo and walk me through the most serious findings."*
- *"List all the OTP rules archdo knows about."*
- *"Explain rule 8.2."*
- *"I'm about to write this aggregate — check it with archdo before I save it."*

### MCP tool call/response example

Request (one line of stdin):

```jsonc
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"archdo_analyze_paths","arguments":{"paths":["lib"],"only":["8.2"]}}}
```

Response (one line of stdout):

```jsonc
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [{"type": "text", "text": "{\"summary\":{...}, \"diagnostics\":[...]}"}],
    "structuredContent": {"summary": {...}, "diagnostics": [...]},
    "isError": false
  }
}
```

The `structuredContent` field is the raw map; `content` is the same data serialized as a single text blob (some clients only consume `content`).

---

## 10. Architecture (how Archdo works internally)

Archdo is a deterministic, single-process analyzer. There's no daemon, no language server, no compiler hook — a Mix task that walks the AST, and optionally reads compiled beam files for ground-truth analysis.

### High-level pipeline

```
   ┌─────────────┐    ┌──────────────┐    ┌──────────────────┐
   │ collect_files│ → │ parse_file   │ → │ phase1 rules     │
   │ (lib, test)  │    │ (literal_enc)│    │ (per-file, 170+) │
   └─────────────┘    └──────────────┘    └────────┬─────────┘
                                                    │
                                                    ▼
                              ┌─────────────────────────────────────┐
                              │ Project-level rules: duplication,   │
                              │ mockability, schema ownership, etc. │
                              └─────────┬───────────────────────────┘
                                        │
                                        ▼
                              ┌─────────────────────────────────────┐
                              │ Optionally: build module graph,     │
                              │ then run graph rules (--boundaries) │
                              └─────────┬───────────────────────────┘
                                        │
                                        ▼
                              ┌─────────────────────────────────────┐
                              │ Optionally: build function graph,   │
                              │ then run function rules (--functions)│
                              └─────────┬───────────────────────────┘
                                        │
                                        ▼
                              ┌─────────────────────────────────────┐
                              │ Optionally: read compiled beam files│
                              │ build Compiled.Graph, run 21 rules  │
                              │ (--compiled): dead code, blast      │
                              │ radius, cycles, API analysis, etc.  │
                              └─────────┬───────────────────────────┘
                                        │
                                        ▼
                              ┌─────────────────────────────────────┐
                              │ filter freeze baseline → format     │
                              │ → write to stdout / return to caller│
                              └─────────────────────────────────────┘
```

### Core modules

| Module                      | Role                                                                        |
|-----------------------------|-----------------------------------------------------------------------------|
| `Archdo`                    | Top-level orchestration. `run/2`, `run_and_format/2`, `freeze_baseline/2`.  |
| `Archdo.Runner`             | Rule registry (`@phase1_rules`, `@graph_rules`) and parallel file analysis. |
| `Archdo.Rule`               | The behaviour every rule implements (`id/0`, `description/0`, `analyze/3`). |
| `Archdo.Diagnostic`         | The finding struct + `error/2`, `warning/2`, `info/2` builders.             |
| `Archdo.Fix`                | One actionable fix option (used inside `Diagnostic.alternatives`).          |
| `Archdo.AST`                | Parsing helpers + AST traversal (`find_all`, `contains?`, `extract_functions`). |
| `Archdo.Graph`              | Module-level dependency graph (built from aliases/imports/calls).            |
| `Archdo.FunctionGraph`      | Function-level call graph (for fan-in/fan-out, feature envy, sync chains).  |
| `Archdo.Metrics`            | Martin package metrics (Ca/Ce/I/A/D).                                       |
| `Archdo.Config`             | `.archdo.exs` loading, layer/context classification.                         |
| `Archdo.Freeze`             | Baseline fingerprinting + filter.                                           |
| `Archdo.Compiled`           | I/O boundary for beam analysis. `analyze/1` returns `{:ok, %Graph{}}`.      |
| `Archdo.Compiled.Graph`     | Complete interaction graph from beam files: modules, calls, indexes, queries.|
| `Archdo.Compiled.Diagram`   | Mermaid diagram generators (overview, context detail, blast radius, delta).  |
| `Archdo.Compiled.DiagramSVG`| SVG module dataflow diagrams with port-based wire routing.                   |
| `Archdo.Compiled.DiagramOTP`| SVG OTP supervision tree diagrams with mailbox icons.                        |
| `Archdo.Compiled.DiagramSystem` | SVG system architecture with horizontal layers and tunnel wires.         |
| `Archdo.Formatter`          | Seven output formats (summary, text, compact, json, llm, sarif, html).      |
| `Archdo.Mcp.Server`         | JSON-RPC 2.0 stdio MCP server with JSV input validation.                    |
| `Archdo.Mcp.SchemaValidator` | Validates tool arguments against `input_schema/0` using JSV.               |
| `Archdo.Mcp.Encoder`        | `Diagnostic` → JSON-friendly map (with MapSet/atom coercion).               |
| `Archdo.Mcp.Tools.*`        | 12 MCP tools (each with `name/0`, `description/0`, `input_schema/0`, `call/1`). |
| `Mix.Tasks.Archdo`          | The `mix archdo` CLI.                                                       |
| `Mix.Tasks.Archdo.Mcp`      | The `mix archdo.mcp` entry point (boots `Archdo.Mcp.Server`).               |

### Rule anatomy

Every rule is a tiny module that implements `Archdo.Rule`:

```elixir
defmodule Archdo.Rules.SomeCategory.SomeRule do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "X.Y"

  @impl true
  def description, do: "Short summary used by archdo_list_rules"

  @impl true
  def analyze(file, ast, _opts) do
    case relevant?(ast) do
      false -> []
      true ->
        # Find offending patterns in the AST, build a Diagnostic per offense.
        ast
        |> find_offenses()
        |> Enum.map(&build_diagnostic(file, &1))
    end
  end

  defp build_diagnostic(file, offense) do
    Diagnostic.warning("X.Y",
      title: "...",
      message: "...",
      why: "...",
      alternatives: [
        Fix.new(summary: "...", detail: "...", applies_when: "..."),
        Fix.new(summary: "...", detail: "...", applies_when: "...")
      ],
      references: ["ARCHITECTURE_RULES.md#X.Y"],
      context: %{...},
      file: file,
      line: offense.line
    )
  end
end
```

Graph rules implement `analyze_graph/2` instead and take a pre-built `%Archdo.Graph{}`.

### How parsing works

`Archdo.AST.parse_file/1` uses `Code.string_to_quoted/2` with `literal_encoder: &{:ok, {:__block__, &2, [&1]}}` so literals are wrapped in `:__block__` nodes. This preserves line metadata for literals (otherwise atoms/numbers lose their line numbers), which the rules need for accurate diagnostics.

A long-standing source of crashes was rules calling `Atom.to_string/1` on macro-generated function names like `{:unquote, _, [...]}`. Every rule that walks function names now guards with `is_atom(name)` first.

### Why no compiler tracer

Archdo started as a design that used `Mix.Tracer` to record every call/import/alias at compile time. We dropped that approach because:

1. It only works at compile time, so you can't run it on third-party code or arbitrary directories.
2. It needs full project compilation to be useful.
3. The maintenance cost of staying in sync with Mix's tracer API is high.

The current pure-AST approach is slower for very large projects (tens of thousands of modules) but works on any directory tree, requires no compilation, and stays compatible across Elixir versions.

---

## 11. Guidance for LLM clients

If you are an LLM agent (Claude Code, Cursor, Cline, Zed, Codex) and you have access to the Archdo MCP server, here is how to use it well.

### When to call Archdo

**Always call it when:**

- The user asks you to "check the architecture", "review the OTP setup", "audit boundaries", or anything similar — **use `archdo_deep_review`** for this, not `archdo_analyze_paths`
- The user asks why a specific module/file feels wrong
- You're about to commit a non-trivial change to an Elixir project — run `archdo_analyze_paths` on the touched files and surface any new diagnostics
- A test failure looks like it might be caused by an architectural smell (sync deadlocks, blocking init, etc.)

**Consider calling it when:**

- The user asks you to refactor an Elixir module — fetch the existing diagnostics first so the refactor addresses real issues, not invented ones
- You're writing new code in an event-sourced project — run `archdo_analyze_file` on what you're about to write
- The user mentions a rule id ("can you fix the 5.11 finding?") — call `archdo_explain_rule` to make sure you understand the rule before acting

**Which tool to pick:**

| User intent | Tool |
|---|---|
| "Check this file quickly" | `archdo_analyze_paths` or `archdo_analyze_file` |
| "Do a full architectural review" | `archdo_deep_review` — then **read the files in the review plan** |
| "How's this project doing?" | `archdo_health` |
| "Check my PR / changed files" | `archdo_diff` with ref `main` |
| "Show me the architecture" | `archdo_diagram` with type `overview` |
| "Any performance issues?" | `archdo_perf_audit` |
| "I'm editing this file, what should I watch for?" | `archdo_suggest` |
| "What's wrong at this line?" | `archdo_explain_finding` |
| "Fix these findings for me" | `archdo_fix` |
| "What rules exist?" | `archdo_list_rules` |
| "Explain rule X" | `archdo_explain_rule` |
| "Check code I'm about to write" | `archdo_analyze_file` |

### How to use `archdo_deep_review` effectively

1. Call `archdo_deep_review` with the project's `lib` path.
2. Read the `diagnostics` section for the structural findings (same as `archdo_analyze_paths`).
3. Read the `review_plan` section. It's ordered by priority (1 = most critical).
4. **For each review plan item:** read the files listed in `files_to_read`, then answer each question in `questions`. The questions are designed to surface issues the static checker cannot see — semantic mismatches, missing domain concepts, resource lifecycle bugs, validation at the wrong layer.
5. Report your findings organized by severity. Cite file:line.
6. When both the static findings and your review-plan answers are complete, synthesize: what are the 3-5 most important things to fix first?

**Don't call it when:**

- The user is asking a documentation question that has nothing to do with their code
- You're writing a one-off script outside an Elixir project
- The user explicitly told you not to

### How to consume a diagnostic

Each `Diagnostic` has the following intent:

1. **`title` + `severity` + `file:line`** — what the finding is and where it lives.
2. **`message`** — the specific instance: which symbol, which call, which count.
3. **`why`** — the underlying architectural reason. Read this so your suggestions are grounded.
4. **`alternatives`** — pre-ranked fix options. **Do not invent your own first.** Use the existing alternatives.
5. **`alternatives[].applies_when`** — read this to pick which alternative fits the user's situation.
6. **`alternatives[].example`** — if present, this is a known-good before/after. Adapt it to the user's code rather than rewriting from scratch.
7. **`references`** — usually `ARCHITECTURE_RULES.md#X.Y`. Open that anchor in the project for canonical context if the `why` doesn't give you enough.
8. **`context`** — structured data the rule already extracted. Use it instead of re-parsing the message.

### The fix-application loop

When the user says "fix this finding":

1. Pick the alternative whose `applies_when` matches the user's situation. If you can't tell, ask.
2. Read the file at `diagnostic.file` to get the surrounding code.
3. Apply the fix in-place, mirroring the structure of the `example` if one is provided.
4. If the rule is one of the false-positive-prone ones (1.5, 4.10, 4.14, etc.), the first alternative is usually "verify this is real" — actually verify before changing code.
5. After applying the fix, re-run `archdo_analyze_file` (or `archdo_analyze_paths` for the touched file) to confirm the diagnostic is gone.
6. If new diagnostics appeared, surface them — don't paper over them.

### Severity → action policy

| Severity   | Default action                                                                       |
|------------|--------------------------------------------------------------------------------------|
| `:error`   | Treat as a blocker. Fix it now or call out that it needs human attention immediately. |
| `:warning` | Default to fixing. If a user says "ignore this", explain the trade-off briefly.       |
| `:info`    | Surface but don't auto-fix. These are judgment calls. Walk the user through the alternatives. |

### Ranking findings

When `archdo_analyze_paths` returns many diagnostics, sort by:

1. `severity` — `error > warning > info`
2. Rule importance — OTP/event-sourcing/boundaries usually come first
3. File proximity — diagnostics in files the user is editing first

The CLI's default `text` format already sorts this way; the JSON/LLM outputs leave sorting to the consumer.

### Things not to do

- **Don't invent rule ids.** Only use ids returned by `archdo_list_rules` or appearing in diagnostics.
- **Don't paraphrase the `why`** when explaining a finding to the user — it's been carefully written. Quote it directly or close to it.
- **Don't suggest fixes that aren't in `alternatives`** unless the user explicitly asks for a different approach. The alternatives are the canonical answers.
- **Don't ignore the freeze baseline.** If the user has `.archdo_baseline.exs`, respect it: pre-existing findings are intentional acceptances, not things to fix.
- **Don't disable `--boundaries` or `--functions`** unless the project is very large and the user is waiting. Both are now enabled by default because they catch the most important architectural issues.

---

## 11.5. Testing Archdo itself

If you're contributing to Archdo or building rules, the test infrastructure has a few conventions worth knowing.

### Test discipline

Archdo follows TDD per the elixir-implementing skill — every new public function in `lib/` has a failing test on disk before the implementation is written. Tests verify *observable behaviour*, not implementation details. Pattern-match assertions are preferred (`assert {:ok, %User{}} = call(...)`) over `==` for shape/structure tests because they produce structural diffs on failure.

The test layout mirrors `lib/`:

```
test/
├── archdo/                  # Tests for primitives (AST, Blackbox, Config, ...)
├── rules/                   # One test file per rule, organized by category
│   ├── boundary/
│   ├── ce/
│   ├── module/
│   └── ...
├── integration/             # Cross-project integration tests (opt-in)
└── support/
    ├── rule_case.ex         # `use Archdo.RuleCase` — assert_flagged / assert_clean
    └── ...
```

### Running tests

```bash
mix test                              # Default suite (1443 tests as of May 2026)
mix test --include integration        # Adds tests in test/integration/ (need /tmp/* repos)
mix test --stale                      # Only files affected by recent changes
mix test test/rules/ce/ce_57_test.exs # One file
```

### Integration-test environment

`test/integration/real_project_test.exs` runs Archdo against pinned-commit checkouts of real Elixir projects under `/tmp` (oban, broadway, finch, req, etc.). These are excluded by default. When `--include integration` is passed and a `/tmp/<repo>` directory is missing or at the wrong commit, the test prints a visible `→ SKIP integration test: /tmp/X missing or wrong commit` and vacuously passes — the suite stays green for contributors who don't have the test corpus checked out. The pattern is a small `defmacrop skip_unless_available/2` defined in the test module; ExUnit has no built-in runtime-skip mechanism, so this is the standard idiom for opt-in environment-dependent tests.

### Writing a rule + test

Each rule has a sibling test file. Use `Archdo.RuleCase` for the `assert_flagged` / `assert_clean` helpers:

```elixir
defmodule Archdo.Rules.Module.MyRuleTest do
  use Archdo.RuleCase
  alias Archdo.Rules.Module.MyRule

  test "fires when X" do
    code = ~S"""
    defmodule MyApp.Bad do
      def thing, do: :the_bad_pattern
    end
    """

    diags = assert_flagged(MyRule, code, file: "lib/my_app/bad.ex")
    assert hd(diags).rule_id == "X.Y"
    assert hd(diags).message =~ "expected substring"
  end

  test "does NOT fire on the good shape" do
    code = ~S"""
    defmodule MyApp.Good do
      def thing, do: :the_good_pattern
    end
    """

    assert_clean(MyRule, code, file: "lib/my_app/good.ex")
  end
end
```

For project-level rules, parse files individually with `Code.string_to_quoted/2` and pass the `[{file, ast}, ...]` list to `analyze_project/1` or `/2` directly.

### Self-analysis tests

Some tests parse Archdo's own source as a regression guard — e.g. `test "Archdo.Compiled.Collector is exempt via @archdo_opaque_state"` reads `lib/archdo/compiled/collector.ex` and asserts no CE-29 diagnostics. These tests guard against accidental marker removal during refactoring. They live in the same test module as the rule they're guarding (no separate self-analysis directory).

```elixir
test "Archdo.Compiled.Collector is exempt via @archdo_opaque_state" do
  ast =
    "lib/archdo/compiled/collector.ex"
    |> File.read!()
    |> Code.string_to_quoted!()

  diags = OpaqueProcessState.analyze("lib/archdo/compiled/collector.ex", ast, [])
  assert diags == []
end
```

The pattern is intentionally low-tech: read the file, parse it, run the rule, assert the expected outcome. No mocks, no fixtures — the production code IS the test fixture. If a future refactor strips the `@archdo_opaque_state` marker, this test fails immediately with a clear diff.

### Shape tolerance — the literal_encoder pattern

The Archdo runner parses files via `Code.string_to_quoted/2` with `literal_encoder: &{:ok, {:__block__, &2, [&1]}}`. This wraps every literal (atoms, strings, numbers) in a `{:__block__, meta, [literal]}` shape so positions are preserved through transformations. Tests, however, often parse code via plain `Code.string_to_quoted/2` without the encoder — atoms and strings are bare in the AST.

This means rule predicates must match BOTH shapes:

```elixir
# WRONG — only matches the literal_encoder shape
defp returns_ok_atom?({:__block__, _, [:ok]}), do: true

# RIGHT — matches both bare and wrapped atoms
defp returns_ok_atom?({:__block__, _, [:ok]}), do: true
defp returns_ok_atom?(:ok), do: true
defp returns_ok_atom?(_), do: false
```

When you find a rule that "works in tests but not in production runs" (or vice versa), this is almost always the cause. Common shape pairs:

| Concept | Bare shape | literal_encoder shape |
|---------|-----------|----------------------|
| Atom literal | `:ok` | `{:__block__, _, [:ok]}` |
| String literal | `"abc"` | `{:__block__, _, ["abc"]}` |
| Tuple literal `{:ok, val}` | `{:ok, var}` | `{{:__block__, _, [:ok]}, var}` |
| Tuple literal pair | `{:ok, _}` (3-tuple is automatic) | `{{:__block__, _, [:ok]}, {:__block__, _, [:_]}}` |
| Keyword `:do` key | `[do: body]` | `[{{:__block__, _, [:do]}, body}]` |

The `Archdo.AST` module provides `unwrap_atom/1` and similar helpers for normalizing. Prefer these over hand-written shape matches when both forms need to be handled.

### Test categories — what each kind of test does

Archdo's test suite organizes by what it's testing:

| Path | Purpose | Async |
|------|---------|-------|
| `test/archdo/<primitive>_test.exs` | Tests for shared primitives (AST, Blackbox, Volatility, Phoenix, Config) | yes |
| `test/rules/<category>/<rule_name>_test.exs` | One test file per rule, named after the rule's module | yes |
| `test/integration/real_project_test.exs` | Cross-project integration tests against pinned `/tmp/<repo>` checkouts | yes (excluded by default) |
| `test/mcp/tools_test.exs` | MCP tool wrappers — JSON-shape contracts | yes |
| `test/runner_test.exs` | The orchestration layer — rule registration, opts plumbing, severity calibration | yes |
| `test/regression_test.exs` | Bug-fix regressions — each test documents the original bug + the failing-input shape | yes |

The test count broke down (May 2026 baseline) approximately as:
- 1100 rule tests
- 200 primitive tests
- 100 runner / orchestration tests
- 30 regression tests
- 12 integration tests (excluded by default)

### TDD discipline — when tests-first is required

Per the elixir-implementing skill §0 (TDD gate), every new public function in `lib/` is written under TDD: failing test on disk first, confirmed RED for the right reason, then minimal implementation to GREEN. The skill's gate fires at three abstraction levels:

1. **Per-function** — before writing `def some_new_function`, name the test file + test name, confirm both exist, run the test, see the failure.
2. **Per-milestone** — before committing a milestone, name every new public function added and the test covering its happy path AND error path.
3. **Bug-fix retrospective** — every bug fix commit must include both the regression test (would have caught the original bug) AND tests for adjacent untested behaviour in the same module.

The skill explicitly excludes a narrow set of cases (`HEEx`/`EEx` templates, CSS, one-off scripts outside `lib/`/`src/`). For everything else in `lib/`, tests-first is mandatory.

In practice, the discipline is enforced by:
- A `[TDD]` tag in user prompts that activates the elixir-implementing skill's PreToolUse hooks
- The `mix archdo --paths lib` self-analysis at commit time, which catches missing `@spec` (rule 2.1) and missing tests (rule 7.x family)
- Code review — the diff should show test files appearing in the same commit OR earlier than the implementation files

### Writing a project-level rule test

Project-level rules (`analyze_project/1` or `/2`) take a `[{file, ast}, ...]` list rather than a single `(file, ast)`. The test pattern is:

```elixir
defmodule Archdo.Rules.CE.MyProjectRuleTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.MyProjectRule

  defp parse(file, code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true,
        # Include literal_encoder if your rule depends on the wrapped shape
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )
    {file, ast}
  end

  describe "MyProjectRule.analyze_project/1" do
    test "fires when condition holds across multiple files" do
      file_asts = [
        parse("lib/myapp/a.ex", ~S"""
        defmodule MyApp.A do
          def thing, do: :the_pattern
        end
        """),
        parse("lib/myapp/b.ex", ~S"""
        defmodule MyApp.B do
          def thing, do: :the_pattern
        end
        """)
      ]

      diags = MyProjectRule.analyze_project(file_asts)
      assert [_diag | _] = diags
      assert hd(diags).rule_id == "CE-X"
    end
  end
end
```

For rules that consume opts (config, threshold overrides, gdpr_scope), pass them via the second arg:

```elixir
config = Archdo.Config.from_keyword([thresholds: [{"CE-X", min_size: 5}]], "/tmp/x")
diags = MyProjectRule.analyze_project(file_asts, config: config)
```

### Snapshot of the Archdo test suite

As of the May 2026 session-end baseline:

```
1443 tests, 0 failures, 129 excluded
```

The 129 excluded are: `:integration` (12 tests requiring `/tmp/*` repos) + `:self_analysis` (a tag for tests that load Archdo against itself; mostly off by default for speed). All 1443 default tests run in ~3.6s with `async: true` throughout — the suite scales well because most tests are pure-function rule tests with no shared state.

When adding a new rule:
- Default to `async: true` (every existing rule test does)
- Use `Archdo.RuleCase` for file-level rules
- Use plain `ExUnit.Case` + `parse/2` helper for project-level rules
- Add at least 3 tests: positive case (fires), negative case (doesn't fire), edge case (the false-positive class the rule is most prone to)
- Add a regression test in `test/regression_test.exs` once the rule has shipped and someone has reported a real-world bug

### When test fixtures need updating

Fixtures inside test files often serve as the rule's specification — `assert_flagged(MyRule, ~S"""...""")` documents what the rule fires on. When a rule's behaviour changes:

1. **Semantic change (e.g., M-Plan9 CE-50 v2):** the rule's behaviour changed deliberately. Existing fixtures that asserted `assert_clean` may now need `assert_flagged` (or vice versa). Update the test to reflect the new contract; the fixture itself stays the same.
2. **Bug fix:** the fixture exposed a bug. Add the fixture to `test/regression_test.exs` permanently; the rule's main test file may stay focused on the happy path.
3. **Strengthened verdict (e.g., M-Plan6 Blackbox.module_verdict):** existing fixtures that "passed by being structurally pure" now need additional constraints (input guards). Update the FIXTURES to include the new constraints, not the rule's behaviour. The test's INTENT (assert "all-pure module is a building block") is preserved; the fixture catches up to the strengthened semantics.

The git history of `test/archdo/blackbox_test.exs` is a good reference — see commits `7d96dc3` and `9fa8ba1` for examples of fixture migration when verdicts strengthened.

---

## 12. Troubleshooting

### "I see `key :suggestion not found` errors"

You're on a stale build from before the diagnostic shape was reworked. Run `mix deps.compile archdo --force` and `mix compile --force`.

### "Boundary rules don't fire"

Cross-file boundary rules (1.1, 1.3, 1.4, 8.4, etc.) only run with `--boundaries`. Without that flag, they're skipped. Also make sure `.archdo.exs` declares the layers/contexts you expect, or that the project follows Phoenix conventions.

### "The function-level rules (1.7, 1.8, 4.9, 6.5) report nothing"

They need `--functions` to build the function call graph. Without it, those rules don't have their input data and emit nothing. Function graph analysis is the slowest mode — expect a few seconds on a large codebase.

### "MCP server starts but Claude Code doesn't see the tools"

Three things to check:

1. Run `mix archdo.mcp` manually from a terminal in the project directory. It should print `archdo MCP server starting (...)` to stderr and wait. If it crashes, the issue is your Mix env.
2. Confirm `.mcp.json` (or your client's equivalent) is in the directory the client launches from. Most clients only re-scan on startup — restart the client.
3. Tail your client's MCP log if it has one. The server logs all errors to stderr with the prefix `[archdo.mcp]`.

### "I get diagnostics on test files I don't expect"

Most rules skip test files via `Archdo.AST.test_file?/1`, which matches paths containing `/test/` or ending in `_test.exs`. If your test layout doesn't match those patterns, the rules will treat tests as production code.

### "The same finding appears multiple times"

Rules with file-level diagnostics (line 0 or 1) can appear once per offense rather than once per file. If that's noise, use `--ignore <rule_id>` to skip the rule, or freeze it.

### "Atom table grows when running on huge projects"

Archdo parses every file with `Code.string_to_quoted/2`, which can intern atoms. Most rules now use string-based comparisons internally, but if you hit the atom limit, run `mix archdo --paths lib` instead of `mix archdo --paths .` so you scan less.

---

## 13. Where to read next

- **[ARCHITECTURE_RULES.md](ARCHITECTURE_RULES.md)** — all 258 rules listed by category with descriptions. Auto-generated from rule modules.

---

*This guide is canonical. If anything in it conflicts with another file, fix the other file.*
