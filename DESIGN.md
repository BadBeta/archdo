# Archdo — Design & Usage Strategy

## The Problem

Architecture checking is fundamentally different from code checking:

| | Credo / Dialyzer | Archdo |
|---|---|---|
| **Unit of analysis** | Single file/module | Relationships between modules |
| **What it needs** | AST of one file | Call graph, dependency graph, supervision tree |
| **Intent** | Inferred from code | Must be **declared** or **conventioned** |
| **Consistency** | Deterministic | Must be deterministic for CI |

The hard part is not checking rules — it's knowing what the architecture *should be* so violations can be detected. A tool can't guess whether `MyApp.Billing` is a context or an internal module unless it's told.

## Solution: Three Tiers

### Tier 1: Mix Compiler Tracer (Deterministic, CI-Ready)

A Mix compiler plugin that builds a project-wide module graph at compile time, then checks rules against it. Runs as `mix archdo` or as a compiler step.

**How it works:**

1. **Compiler tracer** — Elixir's `Mix.Task.Compiler.Diagnostic` and module tracer (`@tracers`) hook into compilation. Every `alias`, `import`, `use`, and remote function call is recorded. This builds:
   - Module dependency graph (who depends on whom)
   - Function call graph (which functions call which)
   - Process graph (which modules start/call which GenServers)

2. **AST analysis** — Post-compilation pass over the AST of each module to detect patterns:
   - `spawn` without supervision
   - `receive` inside GenServer callbacks
   - `send(self(), ...)` in `init/1`
   - `String.to_atom` for process names
   - `GenServer.call(LiteralModule, ...)` outside the defining module
   - Function complexity, arity, struct field counts
   - Missing `@moduledoc`, `@spec`

3. **Architecture declaration** — A `.archdo.exs` config file where developers declare intent:

```elixir
# .archdo.exs
[
  # Layer definitions — what belongs where
  layers: [
    interface: ~r/^MyAppWeb\./,
    domain: ~r/^MyApp\.(?!Repo|Mailer|Infrastructure)/,
    infrastructure: ~r/^MyApp\.(Repo|Mailer|Infrastructure)/
  ],

  # Allowed dependency direction
  # (interface can call domain, domain can call infrastructure, not reverse)
  allowed_deps: %{
    interface: [:domain, :infrastructure],
    domain: [:infrastructure],
    infrastructure: []
  },

  # Context boundaries — each context's public module
  contexts: [
    MyApp.Accounts,
    MyApp.Billing,
    MyApp.Catalog
  ],

  # Modules that are explicitly infrastructure adapters
  adapters: ~r/\.(Adapters?|Impl|Client)\./,

  # Severity overrides
  overrides: [
    {:"5.6", :ignore},  # We're fine with default max_restarts
    {:"6.1", severity: :error, max_public_functions: 15}
  ]
]
```

**What this tier checks (all deterministic):**

| Category | Rules | Method |
|----------|-------|--------|
| Dependency direction | 1.1, 1.3, 1.4 | Graph analysis against declared layers |
| Context encapsulation | 1.2, 2.3 | Call graph vs declared contexts |
| GenServer hygiene | 5.8-5.12, 5.14-5.15 | AST pattern matching |
| Process safety | 5.1, 5.17, 5.21, 5.24, 5.26, 5.30 | AST pattern matching |
| Task safety | 5.22, 5.23 | AST + data flow |
| Module metrics | 6.1-6.3 | Counting |
| Public API | 2.1, 2.2 | AST presence checks |
| Test structure | 7.1, 7.3 | File system + AST |
| NIF safety | 11.1-11.3 | AST pattern matching |

This covers the majority of AST-based rules with fully deterministic, CI-ready checks.

### Tier 1b: Compiled Beam Analysis (Deterministic, Ground Truth)

When `--compiled` is passed, Archdo reads beam files to build a complete interaction graph from ground-truth compiled data. This catches things AST analysis misses:

| Analysis | Rules | Method |
|----------|-------|--------|
| Dead code | 6.24, 6.25 | Exported functions never called (+ transitive) |
| Dependency analysis | 1.18, 4.22, 4.23, 4.26 | Compile hotspots, unused imports, weak/phantom deps |
| API quality | 6.26, 6.27, 6.28, 6.30, 6.31 | Surface weight, exhaustiveness, return shapes, degenerate functions |
| Cycles | 1.19 | Tarjan's SCC on function call graph |
| Boundaries | 1.21, 4.25, 1.22 | Cross-boundary calls, internal module leaks, Repo bypass |
| Context quality | 1.23, 1.24, 1.25 | Cohesion/coupling, circular context deps, orphan modules |
| Testing | 7.21 | Test-only public functions |
| Risk | 1.20 | Change blast radius with transitive dependents |

### Tier 2: Multi-Module Heuristic Analysis (Deterministic, Deeper)

Same Mix task, but engages more expensive analysis that crosses module boundaries and applies heuristics. Opt-in via `mix archdo --deep`.

**What this tier adds:**

| Analysis | Rules | Method |
|----------|-------|--------|
| GenServer call chains | 5.18 | Build inter-GenServer call graph, detect cycles/depth |
| Supervision tree structure | 5.4-5.7 | Parse Application.start, count children, analyze strategies |
| Bottleneck detection | 5.29, 5.31 | Pattern match GenServer state usage across callbacks |
| Unnecessary processes | 5.2, 5.3 | Analyze init + all callbacks for state usage |
| Cast-vs-call analysis | 5.13 | Check handle_cast bodies for error-prone operations |
| Protocol implementation count | 4.2 | Cross-module protocol/impl counting |
| Duplicated validation | 3.1 | Cross-module pattern similarity |
| Event sourcing rules | 8.1-8.4 | Conditional on Commanded dependency |
| State machine rules | 9.1-9.3 | Conditional on gen_statem/fsmx/AshStateMachine usage |

This covers another **~15 rules**. Still deterministic (same code = same results), just slower.

### Tier 3: Claude Code Skill (Judgment Calls, Review Aid)

A Claude Code skill that reads Archdo's Tier 1+2 output plus the source code and provides architectural review with judgment calls that can't be automated.

**What only a skill can do:**

- "This module has 25 public functions — are they cohesive or should this be split?" (requires understanding the domain)
- "These three contexts have similar validation — is this DRY violation or appropriate context independence?" (requires judgment)
- "This GenServer seems unnecessary — is there a state/concurrency/isolation reason?" (requires understanding intent)
- "Should this use a Port instead of a NIF?" (requires understanding the risk profile)
- Reviewing whether toleration exceptions actually apply
- Suggesting architectural refactoring strategies

**The skill reads:**
- `mix archdo --format json` output (structured diagnostics)
- The flagged source files
- `.archdo.exs` declarations

**The skill does NOT:**
- Replace Tier 1+2 (those must pass in CI)
- Produce different results that matter for CI
- Make decisions — it provides analysis for the developer

## Why This Layering Works

```
CI Pipeline:
  mix format --check-formatted    # Formatting
  mix credo --strict               # Code style
  mix dialyzer                     # Types
  mix sobelow                      # Security
  mix archdo                       # Architecture (Tier 1)
  mix archdo --deep                # Architecture (Tier 2, optional)
  mix test                         # Tests

Developer Review:
  Claude Code skill                # Architecture review (Tier 3)
```

**Tier 1+2** catch objective violations — things that are always or usually wrong regardless of context.

**Tier 3** handles the subjective — "is this the right abstraction?" "should this be split?" These inform human decisions.

## Key Design Decision: Declaration vs Convention vs Inference

The tool needs to know what a "context" is, what "infrastructure" is, etc. Three approaches:

| Approach | Pro | Con |
|----------|-----|-----|
| **Convention** | Zero config for Phoenix apps | Breaks for non-Phoenix, Ash, umbrella |
| **Declaration** | Explicit, works everywhere | Requires upfront config |
| **Inference** | No config needed | Unreliable, inconsistent |

**Archdo uses: Convention with declaration override.**

- **Default conventions** baked in for Phoenix (`MyAppWeb.*` = interface, `MyApp.*` = domain, `MyApp.Repo` = infrastructure)
- **`.archdo.exs`** overrides conventions when they don't fit (Ash domains, umbrella apps, custom structures)
- **No inference** — if the tool can't determine a module's layer from convention or declaration, it reports that the module is unclassified rather than guessing

This means a standard Phoenix app gets useful results with zero configuration, while non-standard structures just need a small config file.

## Output Format

```
$ mix archdo

Archdo — Architectural Quality Check

Boundaries
  error  [1.1] MyApp.Accounts imports MyAppWeb.Router.Helpers
         → Domain module must not depend on interface layer
         in lib/my_app/accounts.ex:3

  warning [1.4] MyAppWeb.UserLive.Index calls MyApp.Repo.all
          → Interface must not access Repo directly; use Accounts context
          in lib/my_app_web/live/user_live/index.ex:42

OTP Process Architecture
  error  [5.11] receive block inside GenServer.handle_call
         → Use handle_info for async responses or Task.async/await
         in lib/my_app/worker.ex:28

  warning [5.8] HTTP call (Req.get!) in GenServer.init/1
          → Blocks supervisor startup; move to handle_continue
          in lib/my_app/config_loader.ex:12

  warning [5.24] String.to_atom(user_input) used for process name
          → Atoms are never GC'd; use {:via, Registry, ...} instead
          in lib/my_app/session_manager.ex:8

Module Quality
  warning [6.3] MyApp.Accounts.User has 34 struct fields
          → Erlang maps lose optimization at 32 keys; consider decomposition
          in lib/my_app/accounts/user.ex:5

Found 2 errors, 3 warnings, 0 info.
```

## Implementation: What to Build

### Phase 1 — High-Value Static Checks (smallest useful tool)

Build a Mix task that does AST-only analysis (no compiler tracer needed):

**GenServer/OTP checks (highest value, no config needed):**
- 5.1 — bare spawn/spawn_link
- 5.8 — blocking in init/1
- 5.11 — receive in GenServer callbacks
- 5.12 — send(self()) in init
- 5.14 — silent catch-all handle_info
- 5.15 — timeout as polling
- 5.17 — scattered GenServer.call
- 5.21 — spawn without link/monitor
- 5.22 — Task.async without await
- 5.24 — dynamic atom creation
- 5.26 — unnecessary :global
- 5.30 — Process.sleep in prod

**Module checks (no config needed):**
- 2.1 — missing @moduledoc
- 2.2 — missing @spec
- 6.2 — function complexity/arity
- 6.3 — struct field count

**NIF checks (no config needed):**
- 11.3 — unwrap/panic in Rustler NIFs

These **19 rules** require zero configuration, work on any Elixir project, and are fully deterministic. This is the MVP.

### Phase 2 — Boundary Analysis (needs config or conventions)

Add the compiler tracer and `.archdo.exs`:
- 1.1-1.4 — dependency direction, context encapsulation, circular deps, Repo access
- 2.3 — calls to private modules
- 5.18 — GenServer call chains/deadlocks

### Phase 3 — Deep Analysis

- 5.2-5.7 — supervision tree analysis, unnecessary processes
- 7.1-7.3 — test architecture
- 8.x, 9.x — event sourcing, state machine (conditional)

### Phase 4 — Claude Code Skill

Reads `mix archdo --format json` and provides architectural review.

## Comparison with Existing Tools

| Tool | What it checks | Overlap with Archdo |
|------|---------------|-------------------|
| **Credo** | Code style, complexity, naming | 6.2 (complexity) overlaps — Archdo defers or extends |
| **Dialyzer** | Type specs, contracts | 2.2 (@spec presence) is lighter than Dialyzer's type analysis |
| **Sobelow** | Security (XSS, SQL injection) | None — different domain |
| **Boundary** | Module dependency direction | 1.1, 1.3 overlap — Archdo could delegate to Boundary or reimplement |
| **PrivCheck** | Calls to @doc false functions | 2.3 overlaps — Archdo extends to @moduledoc false |

**Strategy:** Don't reimplement what exists well. If Boundary is a dependency, use it for 1.1/1.3 and focus Archdo on what nothing else checks: OTP patterns, supervision analysis, process communication, test architecture, NIF safety.
