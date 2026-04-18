# Archdo — Architectural Quality Rules for Elixir

> 143 rules that complement Credo (style), Dialyzer (types), and Sobelow (security) by checking **system architecture**, **OTP discipline**, **error handling idioms**, and **test quality** — the gap none of them cover.

## Design Philosophy

These rules must be:
- **Universal** — valid across Phoenix contexts, event sourcing, state machines, OTP, and Ash domains
- **Tolerant** — common patterns in quality Elixir projects on GitHub must pass (validated against 8+ production codebases)
- **Actionable** — each rule produces a clear diagnostic with ranked fix suggestions
- **Checkable** — statically via AST analysis, or heuristically with reasonable confidence

---

## 1. Boundary Integrity (24 rules)

### 1.1 Dependency Direction
Dependencies must flow inward. Domain never depends on interface or infrastructure.

### 1.1b Framework in Domain
Domain modules must not depend on framework-specific packages (Phoenix, Plug, Ecto adapters).

### 1.2 Context Encapsulation
External modules must not reach into a context's internal modules. Use the context's public API.

### 1.3 Circular Dependencies
No circular dependencies between contexts. If A depends on B and B depends on A, merge or extract shared logic.

### 1.4 Repo in Interface
No direct Repo access from interface layer (controllers, LiveViews). Always go through context modules.

### 1.5 Schema Ownership
Each Ecto schema has one owning context. No cross-context schema construction (`%OtherContext.Schema{}`).

### 1.6 Cross-Cutting in Domain
Cross-cutting concerns (Logger, Telemetry) belong at boundaries, not scattered through domain modules. Threshold: >3 Logger calls in a domain module.

### 1.7 Function Boundary
Cross-context calls must target the receiving context's public API, not internal modules.

### 1.8 Shotgun Surgery
Functions with too many distinct callers — changing this function ripples across the codebase.

### 1.9 Time Injection
Time/date calls (DateTime.utc_now, System.system_time) should be injectable for testability. Accept time as a parameter with a default.

### 1.10 Chatty Boundary
Two contexts that call each other >15 times are suspiciously chatty — they may be one concept split incorrectly.

### 1.11 Anemic Context
Contexts too small to justify being a context. Merge with a related context.

### 1.12 Untyped Boundary
Context public APIs returning `map()` or `keyword()` instead of structs. Callers can't rely on the shape.

### 1.13 Sync Context Coupling
Cross-context write operations should consider event-driven decoupling to reduce synchronous coupling.

### 1.14 Unvalidated Params
Controller actions and LiveView callbacks that accept external params without visible validation (changeset, JSV, schema check, or key extraction). Skips fallback controllers and actions that destructure params or delegate to context functions.

### 1.15 Logic in Controller
Controller actions with >300 AST nodes of business logic. Extract to a context module.

### 1.16 Large LiveView Assigns
LiveView with >15 distinct socket assigns. Use streams for collections, split into components.

### 1.17 PubSub Without Handler
LiveView subscribes to PubSub but has no `handle_info/2` to receive broadcasts. Messages pile up in the mailbox.

### 2.1 Missing Moduledoc
Every public module must have `@moduledoc`. Use `@moduledoc false` for internal modules.

### 2.2 Missing Spec
Public functions in documented modules must have `@spec`.

### 2.3 Private Module Calls
No external calls to `@moduledoc false` modules — they are internal implementation details.

---

## 3. Single Source of Truth (6 rules)

### 3.1 Duplicated Code (Type-2 Clones)
Structurally identical functions across modules. Extract into a shared module.

### 3.2 Scattered Config
`System.get_env` called from runtime modules instead of being centralized in `config/runtime.exs`.

### 3.3 Library Config via Application.get_env
Libraries reading `Application.get_env` directly instead of accepting configuration as arguments.

### 3.4 Similar Code (Type-3 Clones)
Functions with >75% structural similarity — close enough to extract a shared abstraction.

### 3.5 Reinvented Enumerable
Manual recursion with `Enum.at/2` where Enum/Stream functions would suffice. O(n²) risk.

### 3.6 Duplicated Validation
Same validation rule appearing in both web and domain layers. Validate in the domain only.

---

## 4. Coupling & Abstraction (21 rules)

### 4.1 Behaviour Size
Behaviours with too many required callbacks. Split into focused interfaces (ISP).

### 4.2 Single-Implementation Protocol
Protocols with only one implementation. May be premature abstraction.

### 4.3 Type Dispatch
Case statements dispatching on atom types suggest missing polymorphism (multi-clause functions or protocols).

### 4.4 External Deps Without Behaviour
External service calls (HTTP, email, AWS) should go through a behaviour boundary for testability.

### 4.5 Import Breadth
Broad `import` without `:only` clause pulls the entire module into namespace.

### 4.6 Unused Dependency
Alias declarations that are never referenced in the file.

### 4.7 God Context
Context with too many sub-modules — likely doing too much.

### 4.8 Mockability
Ratio of direct external IO surfaces vs behaviour seams. Low ratio = hard to test.

### 4.9 Feature Envy
Function calls another module's functions more than its own — the function belongs in the other module.

### 4.10 Speculative Generality
Behaviours with no implementations or only test/mock implementations.

### 4.11 Parallel Hierarchies
Feature additions creating thin files in many directories simultaneously.

### 4.12 Primitive Obsession
Many string parameters that should be typed structs.

### 4.13 Mixed Concerns
Module touching too many distinct concern families.

### 4.14 Natural Seams
Public functions cluster by prefix, suggesting the module should split into sub-modules.

### 4.15 Reinvented PubSub
Custom pubsub/observer implementation using GenServer subscriber lists. Use Registry or Phoenix.PubSub.

### 4.16 Adapters Without Behaviour
Multiple `*Adapter` modules without a shared `@behaviour` contract.

### 4.17 Seam Integrity
Calls to behaviour/protocol implementations bypassing the seam (calling the adapter directly instead of through the behaviour).

### 4.18 Unbounded External Call
External calls (HTTP, GenServer.call) without explicit timeouts.

### 4.19 Missing Telemetry
Context facade modules with many public functions but no `:telemetry.execute` or `:telemetry.span` calls.

### 4.20 Unprotected External Call
External service calls using bang functions (`HTTPoison.get!`) in production code. Use non-bang with ok/error handling.

### 4.21 Fat Interface (ISP)
Behaviour implementations with no-op stubs suggest the interface should be split.

---

## 5. OTP Process Architecture (41 rules)

### 5A. Supervision & Process Lifecycle

**5.1** All long-running processes must be supervised. No bare `spawn/spawn_link`.

**5.2** GenServer used for code organization, not state/concurrency/isolation. Use modules and functions instead.

**5.3** Agent used as read-heavy cache — ETS with `:read_concurrency` would be faster and non-blocking.

**5.4** No flat supervision trees with many children. Group related processes under sub-supervisors.

**5.6** Supervisors should explicitly set `max_restarts`/`max_seconds`, not rely on defaults (3/5).

**5.7** Restart type must match process lifecycle: `:permanent` for long-running, `:transient` for tasks, `:temporary` for one-shot.

### 5B. GenServer Hygiene

**5.8** No blocking work in `init/1`. Use `{:continue, _}` for post-init setup.

**5.9** No blocking operations (HTTP, DB, file I/O) in GenServer callbacks. Offload to Task.

**5.11** No `receive` inside GenServer callbacks — it blocks the GenServer mailbox processing.

**5.12** Use `handle_continue` instead of `send(self(), :init_work)` in init.

**5.13** `GenServer.cast` used where `call` is needed — fire-and-forget when the caller needs confirmation.

**5.14** `handle_info` catch-all must not swallow messages silently. Log unexpected messages.

**5.15** GenServer timeout misuse as polling mechanism. Use `Process.send_after` loop instead.

**5.16** GenServers holding resources (connections, file handles) should implement `terminate/2`.

**5.17** `GenServer.call/cast` should only be used in the defining module's client API, not scattered.

**5.18** No synchronous `GenServer.call` chains from within callbacks — risk of deadlock.

**5.19** Don't send entire `Plug.Conn` or large structs to other processes — copies on send.

**5.37** GenServer without any `handle_info/2` clause. Unexpected messages pile up in mailbox causing memory leak.

**5.38** `GenServer.call` to `__MODULE__` or `self()` from within a callback — instant deadlock.

**5.39** `Process.exit(pid, :kill)` bypasses `terminate/2`. Use `:shutdown` for graceful stop.

**5.41** `GenServer.call` with hardcoded integer timeout. Use a module attribute or parameter.

### 5C. Task Discipline

**5.20** `Process.monitor` without corresponding `:DOWN` handler. Monitor messages go unhandled.

**5.21** `spawn` without link or monitor — failures go unnoticed.

**5.22** `Task.async` without `Task.await` or `Task.yield`. The task result is lost.

**5.23** Tasks should use `Task.Supervisor`, not bare `Task.start/start_link`.

### 5D. ETS Patterns

**5.27** ETS used as message bus between processes. Use message passing instead.

**5.28** Critical ETS tables should configure `:heir` for survival across process restarts.

**5.40** ETS table created in GenServer's `init/1` without cleanup in `terminate/2`. Table leaks on restart.

### 5E. Process Naming & Registry

**5.24** Dynamic atom creation for process names via `String.to_atom`. Atoms are never garbage collected.

**5.25** Custom process lookup maps reinventing Registry. Use the built-in `Registry` module.

**5.26** `:global` registration for local-only processes. Use `Registry` for single-node lookup.

**5.29** Named GenServer handling entity-keyed requests — single-process bottleneck. Use DynamicSupervisor + Registry.

**5.33** GenServer intended as singleton (API uses `__MODULE__`) but `start_link` doesn't register a name.

**5.36** PIDs stored in state or ETS without `Process.monitor`. PIDs become stale after process restart.

### 5F. Process State & Safety

**5.30** `Process.sleep` in production code. Blocks the calling process.

**5.31** GenServer accumulating unbounded data in process state. Use ETS for growing datasets.

**5.32** Process dictionary (`Process.put/get`) — hidden state, hard to test.

**5.34** Unsafe production tracing — `:dbg` and `:erlang.trace` have no safety limits.

**5.35** GenStage consumer subscription without explicit `max_demand`/`min_demand`.

---

## 6. Module Quality (23 rules)

### 6A. Size & Complexity

**6.1** Module cohesion — too many public functions suggests the module does too much.

**6.2** Function complexity (cyclomatic) and arity limits.

**6.3** Struct field count limit — large structs suggest the data model should be decomposed.

**6.4** Module file length — files over 500 lines (warning) or 1000 lines (error) do too much.

**6.5** Function fan-out — individual functions depending on too many distinct modules.

**6.12** Single Responsibility — module has independent function clusters suggesting multiple responsibilities.

### 6B. Naming & Design

**6.6** Boolean flag arguments — `do_thing(true)` should be two named functions.

**6.7** Pretentious names — Manager/Helper/Util/Service hide what the module actually does.

**6.8** Distance from main sequence — Martin metrics (Ca/Ce/I/A/D). Concrete+stable (Zone of Pain) or abstract+unstable.

**6.17** Deeply nested control flow (>4 levels of case/with/if). Extract into named functions.

**6.19** `if/else` for structural dispatch — use multi-clause functions with pattern matching.

### 6C. Error Handling (7 rules)

**6.9** Bare rescue clauses that swallow errors silently. At minimum log, or return `{:error, reason}`.

**6.10** Non-bang functions raising instead of returning ok/error tuples. Whitelists framework callbacks.

**6.11** Module mixes ok/error tuples with raises, nils, and bare returns. Pick one style.

**6.14** `try/rescue` wrapping bang functions — use the non-bang variant with ok/error tuples.

**6.15** Bang calls inside ok/error functions — breaks the contract callers expect.

**6.16** Missing rescue/catch at system boundaries — `GenServer.call` to variable PID needs `catch :exit`; `:erlang.binary_to_term` on untrusted data needs `rescue`.

**6.18** Exception laundering — rescue catches one type and raises a different one. Original stacktrace is lost.

### 6D. Recursion (4 rules)

**6.20** Non-tail recursion — `[head | recurse(tail)]` builds stack frames. Use accumulator pattern.

**6.21** Unnecessary manual list recursion — `[head | tail]` + `[]` base case where Enum suffices.

**6.22** Broken tail-call optimization — recursive call inside `try/rescue`, piped into another function, or used as operand in binary operation. Silently defeats TCO.

**6.23** Unbounded recursion without depth guard or finite base case. Stack overflow risk on large input.

---

## 7. Test Architecture (18 rules)

### 7.1 Test Mirrors Source
Test file structure should mirror source structure (`lib/foo/bar.ex` → `test/foo/bar_test.exs`).

### 7.2 Repo in Tests
Tests should use context APIs, not direct Repo calls.

### 7.3 Mocks Need Behaviours
Every `Mox.defmock` must reference a behaviour module.

### 7.4 Async Eligibility
Test files should declare `async: true` unless they modify global state.

### 7.5 Sleep in Tests
No `Process.sleep` in tests. Use `assert_receive` with explicit timeouts.

### 7.8 Test Naming
Test modules should be named `*Test` in `*_test.exs` files.

### 7.9 No Assertion
Tests must contain at least one assertion.

### 7.10 Trivial Assertion
Tests with trivial assertions like `assert true`, `assert 1 == 1`.

### 7.11 Long Setup
Setup blocks with >400 AST nodes suggest over-coupled test infrastructure.

### 7.12 Long Test
Test bodies with >1200 AST nodes likely test too many things at once.

### 7.13 Mocks Not Verified
Mox setups must call `setup :verify_on_exit!` to enforce expectations.

### 7.14 Coverage Gap
Public API functions not referenced in the corresponding test file.

### 7.15 Mocking Own Modules
Mock at system boundaries only. Don't mock modules you own — test the real implementation.

### 7.16 Runtime Config for DI
`Application.get_env` used at runtime for dependency injection. Use `Application.compile_env` with module attributes.

### 7.17 Generic Test Names
Test names should be descriptive — not "it works", "test 1", "happy path".

### 7.18 Weak Assertion
`assert function()` without pattern match — only checks truthiness. `{:error, reason}` passes because it's truthy.

### 7.19 Missing Test Cleanup
Test starts processes directly without `start_supervised!/1` or `on_exit/1`. Causes test pollution.

### 7.20 Hardcoded Test Data
Test files containing real-looking email addresses (gmail, yahoo), API keys (sk_test_...), or Bearer tokens.

---

## 8. Event Sourcing (8 rules)

### 8.1 Command/Event Naming
Commands use imperative form (CreateAccount), events use past tense (AccountCreated).

### 8.2 Pure Aggregate Apply
`apply/2` must be pure — no side effects. Side effects fire N times on event replay.

### 8.3 Immutable Events
Events must be immutable structs with `defstruct` and `@derive Jason.Encoder`.

### 8.4 Shared Projections
Projectors must not share read models — rebuilding one wipes the other's data.

### 8.5 Events Need Jason.Encoder
Event structs must `@derive Jason.Encoder` for event store serialization.

### 8.6 Projector Reads External
Projectors must not call HTTP/external services or non-deterministic functions. Results change on replay.

### 8.7 Process Manager Reads Projection
Process manager state must come from events, not from Repo reads on projections.

### 8.8 Aggregate Missing Behaviour
Modules with `execute/2` and `apply/2` but no `use Commanded.Aggregates.Aggregate`.

---

## 9. State Machine (3 rules)

### 9.1 State Reachability
All defined states must be reachable from initial states via transitions.

### 9.2 Terminal State Integrity
States named like terminal states (completed, cancelled, failed) should have no outgoing transitions.

### 9.3 Implicit Boolean State
Schemas with 3+ state-suggesting boolean fields (is_active, is_verified, is_suspended) — use a single status enum.

---

## 10. Composition (2 rules)

### 10.1 Shallow Use
Prefer composition over deep `use` chains. More than 2 non-standard `use` statements per module.

### 10.2 Namespace Depth
Module nesting should not exceed the configured maximum depth.

---

## 11. Native Interop (4 rules)

### 11.1 NIF Behind Behaviour
NIF modules should implement a behaviour for replaceability and testing.

### 11.2 NIF Scheduler Safety
NIFs processing variable-size input should use dirty schedulers to avoid blocking the BEAM.

### 11.3 NIF Panic
Rust NIF code must not contain `unwrap()`, `expect()`, `panic!()`, or `todo!()` — panics crash the entire VM.

### 11.4 Port vs NIF
Choose Port when safety matters more than NIF latency. Ports run in a separate OS process.

---

## Rule Summary

| Category | Rules | IDs |
|----------|-------|-----|
| Boundaries | 24 | 1.1–1.17, 2.1–2.3, 4.5–4.8, 4.11, 4.17 |
| Single Source of Truth | 6 | 3.1–3.6 |
| Coupling & Abstraction | 21 | 4.1–4.4, 4.9–4.10, 4.12–4.16, 4.18–4.21 |
| OTP Process Architecture | 41 | 5.1–5.41 |
| Module Quality | 23 | 6.1–6.23 |
| Test Architecture | 18 | 7.1–7.20 |
| Event Sourcing | 8 | 8.1–8.8 |
| State Machine | 3 | 9.1–9.3 |
| Composition | 2 | 10.1–10.2 |
| Native Interop | 4 | 11.1–11.4 |
| **Total** | **143** | |

## Severity Levels

| Severity | Meaning | CLI exit code |
|----------|---------|---------------|
| `:error` | Almost always a bug. Should block PRs. | 2 |
| `:warning` | Almost always wrong, may have legitimate exceptions. | 1 |
| `:info` | Architectural smell, judgment call. For human review. | 0 |

## What These Rules Do NOT Enforce

- **Specific project structure** — flat, umbrella, and poncho are all valid
- **Specific architecture style** — Phoenix contexts, event sourcing, Ash domains all pass
- **Code formatting** — that's `mix format`
- **Naming style** — that's Credo
- **Type correctness** — that's Dialyzer
- **Security vulnerabilities** — that's Sobelow
- **Performance** — that's benchmarking and profiling

These rules fill the gap: **structural quality, boundary integrity, error handling idioms, and test architecture**.
