# Archdo — Architectural Quality Rules for Elixir

> 166 rules that complement Credo (style), Dialyzer (types), and Sobelow (security) by checking **system architecture**, **OTP discipline**, **error handling idioms**, **test quality**, and **compiled beam analysis** — the gap none of them cover.

## Contents

1. [Boundary Integrity](#1-boundary-integrity) — 24 rules (1.1–1.23)
2. [Public API Quality](#2-public-api-quality) — 3 rules (2.1–2.3)
3. [Single Source of Truth](#3-single-source-of-truth) — 6 rules (3.1–3.6)
4. [Coupling & Abstraction](#4-coupling--abstraction) — 26 rules (4.1–4.26)
5. [OTP Process Architecture](#5-otp-process-architecture) — 40 rules (5.1–5.42)
6. [Module Quality](#6-module-quality) — 31 rules (6.1–6.32)
7. [Test Architecture](#7-test-architecture) — 19 rules (7.1–7.21)
8. [Event Sourcing](#8-event-sourcing-architecture) — 8 rules (8.1–8.8)
9. [State Machine](#9-state-machine-architecture) — 3 rules (9.1–9.3)
10. [Composition](#10-composition-and-extensibility) — 2 rules (10.1–10.2)
11. [Native Interop](#11-native-interop-nifs-ports-rustler) — 4 rules (11.1–11.4)

## Design Philosophy

These rules must be:
- **Universal** — valid across Phoenix contexts, event sourcing, state machines, OTP, and Ash domains
- **Tolerant** — common patterns in quality Elixir projects must pass (validated against 8+ production codebases)
- **Actionable** — each rule produces a clear diagnostic with ranked fix suggestions
- **Checkable** — statically via AST analysis, via compiled beam analysis (ground-truth after macro expansion), or heuristically with reasonable confidence

Rules are organized by architectural concern. Each rule has:
- A short name and description
- **Why** — the architectural principle it enforces
- **Check** — how to detect violations
- **Tolerate** — known exceptions that should not be flagged
- **Severity** — `error` (almost always wrong), `warning` (usually wrong), `info` (worth reviewing)

---

## 1. Boundary Integrity

### 1.1 Dependency Direction (Hexagonal Architecture)

Dependencies must flow inward. The domain core depends on nothing external. Interface and infrastructure layers depend on the domain, never the reverse.

```
┌─────────────────────────────────────────────┐
│  Interface Layer (MyAppWeb.*, CLI, API)      │
│    Controllers, LiveViews, Channels, Plugs   │
│                     │                        │
│                     ▼                        │
│  ┌─────────────────────────────────────┐     │
│  │  Domain Layer (MyApp.*)             │     │
│  │    Contexts, Schemas, Business Logic│     │
│  │    Behaviours (ports) defined here  │     │
│  └──────────────┬──────────────────────┘     │
│                 │                             │
│                 ▼                             │
│  Infrastructure Layer                        │
│    Repo, HTTP clients, Email, File I/O       │
│    Adapters implement domain behaviours      │
└─────────────────────────────────────────────┘
```

- **Why:** Core principle of Clean/Hexagonal architecture. Domain modules that reference web/framework modules cannot be reused, tested independently, or survive framework changes. (SOLID-D, Hexagonal Architecture, Ports & Adapters)
- **Check:** Build a module dependency graph. Flag edges that flow Domain→Interface, Infrastructure→Interface, or Domain→Infrastructure concrete modules.
- **Tolerate:** `Ecto.Changeset` in web layer, `Phoenix.PubSub` in domain (general-purpose), Ecto in domain (standard Phoenix convention).
- **Severity:** `error`

### 1.1b Framework in Domain

Domain modules must not depend on framework-specific packages (Phoenix, Plug).

- **Why:** If your domain `use`s or `import`s a Phoenix-specific package, the domain cannot be extracted, reused in a CLI tool, or tested without Phoenix. (Framework Independence)
- **Check:** Flag `alias`, `import`, or `use` of `Phoenix.HTML`, `Phoenix.LiveView`, `Phoenix.Router.Helpers`, `Plug.Conn` from domain modules.
- **Tolerate:** `Phoenix.PubSub`, `Ecto.*`, Ash Framework modules.
- **Severity:** `warning`

### 1.2 Context Encapsulation

External modules must not reach into a context's internal modules. Access goes through the context's public API.

- **Why:** Contexts are bounded contexts — their internal structure is an implementation detail. Bypassing the public API creates hidden coupling. (Single Responsibility, Information Hiding)
- **Check:** Identify context boundaries. Flag calls from outside a context to modules nested inside it (e.g., `MyApp.Accounts.UserQuery` called from `MyAppWeb.UserController`). Internal modules are `@moduledoc false` or nested more than one level.
- **Tolerate:** Schema references for pattern matching, `defdelegate` targets, Ash resources through their Domain.
- **Severity:** `warning`

### 1.3 No Circular Dependencies Between Contexts

Context A must not depend on Context B if B already depends on A.

- **Why:** Circular dependencies make it impossible to reason about, test, or deploy contexts independently. They indicate mixed responsibilities. (Acyclic Dependencies Principle)
- **Check:** Build a directed graph of context-to-context calls. Detect cycles. Report the shortest cycle path.
- **Tolerate:** Shared foundational contexts depended on by many, PubSub-mediated communication.
- **Severity:** `error`

### 1.4 No Direct Repo Access from Interface Layer

Controllers, LiveViews, and channels should not call Repo directly. Use context modules.

- **Why:** Repo calls in controllers couple the web layer to the database schema. Business rules cannot be reused from other entry points (CLI, background jobs). Testing requires the full HTTP stack. (Separation of Concerns)
- **Check:** Flag `Repo.get`, `Repo.insert`, `Repo.all`, etc. in files under `*_web/` or `controllers/`.
- **Tolerate:** Ecto sandbox setup in test helpers, Repo calls in tasks/seeds.
- **Severity:** `warning`

### 1.5 Schema Ownership

Each Ecto schema should have one owning context. Other contexts should not directly construct schemas they don't own.

- **Why:** Schemas are the data shape of a context. When another context constructs `%OtherContext.Schema{}` directly, it bypasses validation and creates hidden coupling. (Bounded Context, Information Hiding)
- **Check:** Build a map of Schema→owning context. Flag direct construction (`%Schema{field: value}`) from outside the owning context.
- **Tolerate:** Schema references for pattern matching, test fixtures and factories, read-side projections.
- **Severity:** `info`

### 1.6 Cross-Cutting Concerns in Domain

Cross-cutting concerns (Logger, Telemetry) belong at boundaries, not scattered through domain modules.

- **Why:** Logging is infrastructure. When the domain layer is full of Logger calls, it depends on Logger's runtime and can't be tested in isolation. Cross-cutting concerns belong at the boundaries where they can be turned on/off without touching business logic. (Separation of Concerns)
- **Check:** Count Logger calls in domain modules. Flag modules with >3 Logger calls that aren't in web/adapter/infrastructure directories.
- **Tolerate:** Web layer, adapters, infrastructure, modules with "telemetry" in the name.
- **Severity:** `info`

### 1.7 Function-Level Boundary

Cross-context calls must target the receiving context's public API, not internal functions.

- **Why:** Even when module-level encapsulation is respected, calling an internal public function of a deeply-nested module bypasses the context's intended API surface. The context facade exists to control access — bypassing it couples callers to internal structure. (API Surface Control)
- **Check:** Uses FunctionGraph to detect calls that cross context boundaries and target non-facade modules.
- **Tolerate:** Schema modules, delegate targets, shared types.
- **Severity:** `info`

### 1.8 Shotgun Surgery

Functions with too many distinct callers from different modules — changing this function creates a ripple effect across the codebase.

- **Why:** High afferent coupling (many incoming dependencies) means any change to this function requires checking and potentially updating many callers. This is the "shotgun surgery" code smell — a single change requires many small edits across the codebase. (Coupling Metrics)
- **Check:** Count distinct calling modules per function using FunctionGraph. Flag functions above threshold.
- **Tolerate:** Utility functions (String, Enum wrappers), context facade functions (designed for many callers).
- **Severity:** `info`

### 1.9 Time Injection

Time/date calls (`DateTime.utc_now`, `System.system_time`) should be injectable for testability.

- **Why:** Reading the wall clock directly makes code untestable: tests can't pin time, can't simulate time-dependent edge cases (timezones, midnight rollovers, scheduled jobs), and can't make assertions about durations without flakiness. Domain code that depends on "now" should accept the clock from outside so tests can swap in a known value. (Dependency Injection, Testability)
- **Check:** Flag direct calls to `DateTime.utc_now/0`, `Date.utc_today/0`, `NaiveDateTime.utc_now/0`, `System.system_time/0,1`, `System.monotonic_time/0,1` in non-infrastructure modules.
- **Tolerate:** Test files, infrastructure modules, modules with "clock" or "time" in the path, adapter modules.
- **Severity:** `info`

### 1.10 Chatty Boundary

Two contexts that call each other more than 15 times are suspiciously chatty — they may be one concept split incorrectly.

- **Why:** When two contexts call each other constantly, the boundary stops carrying its weight: the modules are coupled in practice but you pay for the indirection of going through public APIs. Heavy chatter is usually a sign that the two contexts are really one concept split prematurely, or that an underlying shared concept wants to be extracted. (Coupling Metrics, Context Design)
- **Check:** Count cross-context call edges using FunctionGraph. Flag pairs where the bidirectional call count exceeds 15 (warning) or 40 (error).
- **Tolerate:** N+1-style fine-grained calls that should be replaced with a bulk API.
- **Severity:** `info` / `warning`

### 1.11 Anemic Context

Contexts too small to justify being a context — fewer than a minimum number of sub-modules.

- **Why:** A context with one schema and two functions isn't a bounded context — it's unnecessary indirection. It adds a layer of abstraction without providing any encapsulation benefit. Merge it with a related context. (Architecture Overhead)
- **Check:** Count sub-modules per context. Flag contexts with very few modules.
- **Tolerate:** New contexts being built up incrementally, intentionally minimal APIs.
- **Severity:** `info`

### 1.12 Untyped Boundary

Context public APIs returning `map()`, `keyword()`, or `list()` in their `@spec` instead of structs.

- **Why:** When a public function returns an untyped map, callers can only discover its shape by reading the source. There is no compile-time check on field names, no IDE help, and renaming a key silently breaks every consumer. Defining a struct turns those leaks into discoverable, documented contracts. (Contract Design)
- **Check:** Find `@spec` declarations in context-level modules (directly under `lib/app_name/`) that return `map()`, `keyword()`, or `list()`.
- **Tolerate:** Non-context files, deeply nested modules.
- **Severity:** `info`

### 1.13 Sync Context Coupling

Cross-context write operations should consider event-driven decoupling to reduce synchronous coupling.

- **Why:** Synchronous cross-context writes create tight coupling where both contexts must be available simultaneously. If the target context's database is slow or down, the caller blocks. Event-driven patterns (PubSub, Oban) allow each context to operate independently with eventual consistency. (Loose Coupling, Resilience)
- **Check:** Detect cross-context calls that modify state (create/update/delete operations).
- **Tolerate:** Read-only cross-context calls, small applications, operations requiring immediate consistency.
- **Severity:** `info`

### 1.14 Unvalidated Params at Boundary

Controller actions and LiveView callbacks that accept external params without visible validation.

- **Why:** Controllers and LiveViews are system boundaries — the first place external data enters the application. Passing raw params deeper into the domain without casting, validating, or schema-checking them means invalid data travels further before being caught, error messages become less actionable, and the domain layer must defend itself against arbitrary shapes. Validate at the boundary and pass clean data inward. (Boundary Validation)
- **Check:** Flag controller actions (arity 2) with a raw `params` variable that don't call validation functions (changeset, cast, validate, JSV) or delegate to context functions (create_*, update_*, register). Skip fallback controllers and destructured params (shows documented intent).
- **Tolerate:** Fallback controllers, actions that destructure params in function head, actions that delegate to known context functions.
- **Severity:** `info`

### 1.15 Logic in Controller

Controller actions with >300 AST nodes of business logic. Controllers should be thin dispatchers: receive params, call a context function, render a response.

- **Why:** Business logic in controllers can't be reused from LiveViews, background jobs, or other contexts. It also can't be tested without HTTP plumbing. OAuth callbacks, file generation, and API formatting that exceeds the threshold should be extracted into dedicated service modules or context functions. (Separation of Concerns)
- **Check:** Measure AST size of controller action bodies (arity 2 public functions in controller files). Flag actions exceeding 300 nodes.
- **Tolerate:** OAuth callback controllers (inherently complex but should still be extracted), small utility controllers.
- **Severity:** `info`

### 1.16 Large LiveView Assigns

LiveView with >15 distinct socket assigns. Use streams for collections, split into components.

- **Why:** Every socket assign is serialized and diffed on each render cycle. Large numbers of assigns increase memory per connection and slow down the diff engine. Collections assigned directly (lists of records) are the worst — use streams instead, which only send diffs. Many assigns also signal the LiveView is doing too much and should be split into focused live components. (LiveView Performance, Component Design)
- **Check:** Count distinct assign keys across mount/handle_event/handle_info (including piped `|> assign(:key, val)` patterns). Flag modules exceeding 15 assigns.
- **Tolerate:** LiveView components that aggregate data for complex displays.
- **Severity:** `info`

### 1.17 PubSub Without Handler

LiveView subscribes to PubSub but has no `handle_info/2` to receive broadcasts.

- **Why:** `PubSub.subscribe` sets up a subscription, but broadcasts arrive as regular process messages. Without `handle_info/2`, the messages pile up in the LiveView process mailbox — consuming memory, never being processed, and making the subscription effectively dead code. (Silent Resource Leak)
- **Check:** Detect `.subscribe` calls in LiveView modules that lack `handle_info/2` definitions or `attach_hook` for `:handle_info`.
- **Tolerate:** LiveViews using `attach_hook` in `on_mount` for zero-boilerplate broadcast handling.
- **Severity:** `warning`

### 1.18 Compile Dependency Hotspot *(compiled)*

Module depended on by many others — changes trigger cascading recompilation.

- **Why:** Modules at the center of the dependency graph become recompilation bottlenecks. Changing a module with 50+ dependents forces all of them to recompile, slowing development cycles. Struct and behaviour changes cause broader recompilation than function-body changes. (Build Performance, Change Isolation)
- **Check:** Build compiled call graph. Count transitive dependents for each module. Flag modules with >10 dependents.
- **Tolerate:** Core utility modules (AST helpers, type modules) that are stable and rarely change.
- **Severity:** `info`

### 1.19 Circular Function Calls *(compiled)*

Function-level circular call chain between modules detected via Tarjan's SCC algorithm.

- **Why:** A circular call chain between functions in different modules (A.foo → B.bar → A.foo) creates tight coupling. Module-level cycles (rule 1.3) are coarser — this identifies the exact functions involved, making the cycle actionable. (Dependency Acyclicity, Testability)
- **Check:** Build function-level call graph from compiled beams. Run Tarjan's SCC. Report cycles that span 2+ modules (intra-module recursion is normal).
- **Tolerate:** Mutual recursion within a single module.
- **Severity:** `warning`

### 1.20 High Change Blast Radius *(compiled)*

Module change affects many transitive dependents across multiple dependency layers.

- **Why:** Changes to high-blast-radius modules ripple through the codebase. The risk score combines: number of transitive dependents, dependency depth, whether the module defines structs or behaviours (broader recompilation impact). High scores demand careful review and thorough testing. (Change Isolation, Risk Management)
- **Check:** Walk the dependency graph outward from each module. Compute transitive dependents by depth. Calculate risk score with struct/behaviour weighting.
- **Tolerate:** Core infrastructure modules whose central role is by design (Repo, PubSub).
- **Severity:** `warning`

### 1.21 Cross-Boundary Call Bypasses Context API *(compiled)*

Module in one context calls an internal module in another context directly, bypassing the boundary module.

- **Why:** Compiled analysis confirms this is a ground-truth dependency after macro expansion — not an AST guess. Calling internal modules across context boundaries creates hidden coupling. Changes to the internal module can break callers in other contexts without warning. (Context Encapsulation, Information Hiding)
- **Check:** Build compiled call graph. For calls between modules in different contexts, flag when the callee is an internal module (not the context boundary module itself).
- **Tolerate:** Shared utility modules intentionally designed for cross-context use.
- **Severity:** `warning`

### 1.22 Direct Repo Access Outside Context *(compiled)*

Non-context module calls Repo functions directly instead of going through the owning context.

- **Why:** Only context boundary modules should access the Repo — this ensures data access is encapsulated and business rules are enforced consistently. Direct Repo calls bypass validation, authorization, and cross-cutting concerns the context provides. Compiled data catches Repo calls injected by macros. (Data Encapsulation, Single Responsibility)
- **Check:** Find all calls to Repo.get/insert/update/delete/all from non-context modules. Context modules are identified as top-level domain modules.
- **Tolerate:** Migration modules, context-internal submodules explicitly delegated by the context.
- **Severity:** `warning`

---

## 2. Public API Quality

### 2.1 Missing @moduledoc

Every public module must have `@moduledoc`. Internal modules should use `@moduledoc false`.

- **Why:** Undocumented modules are invisible to ExDoc, hard to discover, and impossible to evaluate without reading the code. `@moduledoc false` explicitly marks internal modules — it's different from simply omitting the attribute (which is ambiguous). (Documentation, Discoverability)
- **Check:** Flag `defmodule` without `@moduledoc` attribute.
- **Tolerate:** Test modules, short schema modules (debatable).
- **Severity:** `info`

### 2.2 Missing @spec

Public functions in documented modules must have `@spec`.

- **Why:** `@spec` serves triple duty: documentation for humans, input for Dialyzer's type checking, and contract specification for callers. A module with `@moduledoc` that lacks `@spec` on public functions has incomplete documentation. (Type Safety, Documentation)
- **Check:** Flag `def` functions without a preceding `@spec` in modules that have `@moduledoc` (not `@moduledoc false`).
- **Tolerate:** Modules with `@moduledoc false`, framework callbacks (GenServer, Phoenix, Ecto).
- **Severity:** `info`

### 2.3 Private Module Calls

No external calls to `@moduledoc false` modules — they are internal implementation details.

- **Why:** `@moduledoc false` signals "this module is internal — don't depend on it." Calling it from outside creates hidden coupling to implementation details that the author explicitly marked as private. (Encapsulation)
- **Check:** Detect function calls from other modules to modules marked `@moduledoc false`.
- **Tolerate:** Test files, same-context calls.
- **Severity:** `warning`

---

## 3. Single Source of Truth

### 3.1 Duplicated Code (Type-2 Clones)

Structurally identical functions across modules. Multiple functions with the same AST shape but different identifiers — copy-paste code.

- **Why:** Duplicated logic means bugs must be fixed in multiple places. Structural clones (same AST shape, different identifiers) are the worst — they look different but behave identically. Over time, one copy gets a fix the other doesn't. (DRY Principle)
- **Check:** Compute AST fingerprints for all functions above a minimum size. Compare pairwise. Flag functions with identical structure (Type-2 clone). Report the clone groups.
- **Tolerate:** Test setup functions (intentional repetition for clarity), simple getters/setters, framework callbacks with standard shapes.
- **Severity:** `warning`

### 3.2 Scattered Config

`System.get_env` called from runtime modules instead of being centralized in `config/runtime.exs`.

- **Why:** Environment variables scattered across modules are impossible to audit, document, or change centrally. A single missing env var is a runtime crash. Centralizing in `config/runtime.exs` makes all required env vars visible in one place, deployable via one mechanism, and testable with one config override. (Configuration Management)
- **Check:** Flag `System.get_env/1,2`, `System.fetch_env/1`, `System.fetch_env!/1` outside config files and release modules.
- **Tolerate:** `config/runtime.exs`, release modules, test helpers.
- **Severity:** `warning`

### 3.3 Library Config via Application.get_env

Libraries reading `Application.get_env` directly instead of accepting configuration as arguments.

- **Why:** `Application.get_env` in a library captures config at runtime — consumers must configure before calling. Accepting config as function arguments makes the library composable, testable, and usable with different configurations in the same application. Application code (not libraries) can use `Application.compile_env` safely. (Library Design)
- **Check:** Flag `Application.get_env/2,3` and `Application.fetch_env!/2` in non-application modules.
- **Tolerate:** Application modules (`use Application`), config files, release modules.
- **Severity:** `warning`

### 3.4 Similar Code (Type-3 Clones)

Functions with >75% structural similarity — close enough to extract a shared abstraction with parameters for the differences.

- **Why:** Near-identical functions diverge over time. One gets a bug fix, the other doesn't. Two functions that share 80% of their logic should share one implementation with the 20% difference parameterized. (DRY, Maintainability)
- **Check:** Compute shingle-based (n-gram) similarity between function ASTs. Flag pairs above 75% similarity with minimum size threshold (25 AST nodes).
- **Tolerate:** Small functions (<25 nodes), framework callbacks, test helpers.
- **Severity:** `info`

### 3.5 Reinvented Enumerable

Manual recursion with `Enum.at/2` where Enum/Stream functions would suffice. Creates O(n²) performance.

- **Why:** `Enum.at/2` is O(n) for lists. A recursive function that calls `Enum.at` on each iteration becomes O(n²) — fine for tiny lists but a quadratic surprise on real data. The pattern also reinvents iteration primitives that Elixir provides via Enum.reduce, Enum.with_index, and Stream. (Performance, Idiomatic Elixir)
- **Check:** Flag recursive functions that call `Enum.at/2` in their body.
- **Tolerate:** Test files.
- **Severity:** `info`

### 3.6 Duplicated Validation

Same validation rule appearing in both web and domain layers.

- **Why:** When the same validation check lives in two layers, the web layer either silently diverges from the domain (requests pass at the edge but fail later), or both stay in lockstep at the cost of duplicate maintenance for every rule change. Validation is a domain concern — the web layer should ask the domain whether the input is valid, not re-implement the check. (Single Source of Truth)
- **Check:** Project-level: compare validation patterns between web and domain modules. Flag overlapping validation function names.
- **Tolerate:** Web-layer shape validation (JSON parseable, field exists) vs domain-layer business rules (different kinds of checks).
- **Severity:** `info`

---

## 4. Coupling & Abstraction

### 4.1 Behaviour Size

Behaviours with too many required callbacks. Split into focused interfaces.

- **Why:** A behaviour with 10 callbacks forces every implementation to provide all 10 — even if most are no-ops for a particular implementation. This violates the Interface Segregation Principle: clients should not be forced to implement interfaces they don't use. (SOLID-I)
- **Check:** Count `@callback` declarations per behaviour module. Flag above threshold (default: 8).
- **Tolerate:** Framework behaviours (GenServer has 7, Plug has 2), behaviours with `@optional_callbacks`.
- **Severity:** `info`

### 4.2 Single-Implementation Protocol

Protocols with only one implementation. May be premature abstraction.

- **Why:** A protocol is a polymorphism mechanism — its value comes from dispatch across multiple types. With one implementation, the indirection adds complexity without benefit. Wait until a second implementation is needed, then introduce the protocol. (YAGNI)
- **Check:** Count `defimpl` across the project per protocol. Flag protocols with exactly 1 implementation (excluding `Any`).
- **Tolerate:** Protocols implementing `Any` (default fallback), protocols for external types not defined in the project.
- **Severity:** `info`

### 4.3 Type Dispatch

Case statements dispatching on atom types suggest missing polymorphism.

- **Why:** A `case` with 5+ clauses each matching a different atom in the same position is a manual virtual dispatch table. Multi-clause functions with pattern matching or protocols express this more clearly and are extensible without modifying the dispatch site. (Open/Closed Principle)
- **Check:** Flag case/cond expressions with many clauses (5+) matching atom literals as the first element of the matched value.
- **Tolerate:** Protocol implementations, state machine transitions, configuration dispatch.
- **Severity:** `info`

### 4.4 External Deps Without Behaviour

External service calls (HTTP, email, AWS) should go through a behaviour boundary for testability.

- **Why:** Direct calls to HTTPoison, Swoosh, ExAws in domain code make tests slow, flaky, and dependent on network. A behaviour gives Mox a clean seam — tests swap one mock instead of monkey-patching or hitting real services. (Dependency Inversion, Testability)
- **Check:** Flag calls to known external IO libraries (HTTPoison, Finch, Req, Tesla, Swoosh, Bamboo, ExAws, Stripe, File) from non-adapter modules.
- **Tolerate:** Adapter modules, infrastructure layer, self-calls (library calling itself).
- **Severity:** `info`

### 4.5 Import Breadth

Broad `import` without `:only` clause pulls the entire module into namespace.

- **Why:** Unqualified imports make it impossible to tell which module a function comes from at the call site. `import Module` without `only:` is the worst — every public function enters the namespace, creating invisible dependencies and name collision risks. (Readability, Coupling)
- **Check:** Flag `import Module` without `only:` option.
- **Tolerate:** DSL modules designed for full import (Ecto.Query, Ecto.Changeset, Phoenix guards, test helpers).
- **Severity:** `warning`

### 4.6 Unused Dependency

Alias declarations that are never referenced in the file.

- **Why:** Unused aliases create phantom dependencies: the file declares it depends on the module but never actually calls it. They survive across refactors, accumulate over time, and make the dependency graph misleading. Removing them is free maintenance. (Dead Code)
- **Check:** Count occurrences of the alias short name in the file. Flag if only 1 (the alias declaration itself).
- **Tolerate:** Aliases used in sigils, heredocs, or templates.
- **Severity:** `info`

### 4.7 God Context

Context with too many sub-modules — likely doing too much.

- **Why:** A context with 30 sub-modules has outgrown its bounded context. The name no longer describes a cohesive concept — it's become an organizational dump for unrelated functionality. Split into focused contexts. (Single Responsibility, Context Design)
- **Check:** Count sub-modules per context. Flag above threshold.
- **Tolerate:** Intentionally large contexts with clear internal sub-organization (schemas/, queries/, workers/).
- **Severity:** `info`

### 4.8 Mockability Score

Ratio of direct external IO surfaces vs behaviour seams in the project.

- **Why:** A healthy mockability ratio means almost every external dependency has a behaviour seam. When the ratio is low (many direct IO calls, few behaviours), tests can't swap dependencies cleanly and end up either hitting real services or using brittle mocking approaches. (Testability)
- **Check:** Project-level: count modules with direct external IO calls vs modules with `@behaviour` declarations. Report ratio and per-file diagnostics.
- **Tolerate:** Adapters, infrastructure, test files.
- **Severity:** `info`

### 4.9 Feature Envy

Function calls another module's functions much more than its own — the function belongs in the other module.

- **Why:** When a function reaches into another module much more than its own, that other module is where the function naturally belongs. Splitting the function from the data it operates on creates feature envy: the caller module knows nothing useful and the dependency direction is wrong. (Coupling, Cohesion)
- **Check:** Using FunctionGraph, count outgoing calls per target module per function. Flag when external calls exceed self-calls by the envy ratio (3x) with minimum external calls (4).
- **Tolerate:** Stdlib calls (Enum, Map, String, Kernel), thin wrapper functions.
- **Severity:** `info`

### 4.10 Speculative Generality

Behaviours with no implementations or only test/mock implementations.

- **Why:** A behaviour without implementations is speculative generality — an abstraction added in anticipation of variants that never arrived. The cost is real (callers go through dispatch, readers chase the impl) but the benefit (multiple implementations) is hypothetical. (YAGNI)
- **Check:** Project-level: find behaviour declarations (`@callback`) and match against `@behaviour` usages. Flag behaviours with zero implementations or only test/mock implementations.
- **Tolerate:** Implementations in sibling apps, external packages.
- **Severity:** `info`

### 4.11 Parallel Hierarchies

Feature additions creating thin files in many directories simultaneously.

- **Why:** When adding one feature requires creating files in 5+ directories with the same basename, the architecture forces boilerplate. Each thin file adds maintenance cost without adding value. (Architecture Smell)
- **Check:** Group files by basename across directories. Flag basenames appearing in many parallel directories with thin implementations (below node threshold).
- **Tolerate:** Intentional domain decomposition with meaningful per-directory logic.
- **Severity:** `info`

### 4.12 Primitive Obsession

Many string parameters that should be typed structs.

- **Why:** Functions taking 3+ string parameters for distinct concepts (name, email, phone) lose type safety. A struct makes the intent explicit, enables compile-time field checking, and prevents argument-order bugs. (Type Safety)
- **Check:** Flag functions with multiple string-typed parameters above threshold.
- **Tolerate:** Low-level string processing functions, format/render functions.
- **Severity:** `info`

### 4.13 Mixed Concerns

Module touching too many distinct concern families.

- **Why:** A module that does HTTP, database, email, file I/O, and logging has too many responsibilities. It becomes a dependency magnet and change magnet — modifications to any concern require touching this module. (Single Responsibility)
- **Check:** Count distinct concern families referenced by a module (HTTP clients, Repo, File, Logger, email, etc.). Flag above threshold.
- **Tolerate:** Facade modules, orchestration modules that intentionally coordinate.
- **Severity:** `info`

### 4.14 Natural Seams

Public functions cluster by prefix, suggesting the module should split into sub-modules.

- **Why:** When a module has `list_users`, `create_user`, `delete_user`, `list_posts`, `create_post`, `delete_post`, the user_* and post_* functions are natural seams. Each prefix group has higher internal cohesion than cross-group cohesion. (Cohesion, SRP)
- **Check:** Group public functions by common prefix. Flag prefix groups with many functions above threshold.
- **Tolerate:** Small modules, context facades with intentional breadth.
- **Severity:** `info`

### 4.15 Reinvented PubSub

Custom pubsub/observer implementation using GenServer subscriber lists instead of Registry or Phoenix.PubSub.

- **Why:** Phoenix.PubSub, Registry (`:duplicate` keys), and `:pg` already solve the subscriber-list problem with concurrent dispatch, automatic cleanup when subscribers die, and (in PubSub's case) cluster-wide fanout. A custom GenServer-as-pubsub typically loses cleanup on process death, becomes a single bottleneck for all dispatch, and accumulates dead pids. (Standard Library, Reliability)
- **Check:** Flag GenServer modules that have subscribe/broadcast/notify-like functions AND maintain a subscriber list (`:subscribers` in state) without delegating to Registry or PubSub.
- **Tolerate:** Modules that wrap PubSub/Registry with additional logic.
- **Severity:** `warning`

### 4.16 Adapters Without Behaviour

Multiple `*Adapter` modules in the same namespace without a shared `@behaviour` contract.

- **Why:** When two or more `*Adapter` modules live side-by-side without a shared behaviour, the implicit contract between them only exists in your head. Adding a method to one and forgetting to add it to the other compiles fine but breaks at runtime, and Mox can't generate a verifying mock for an undocumented contract. (Interface Contract)
- **Check:** Project-level: group modules by `*Adapter` or `*Client` suffix by parent namespace. Flag groups of 2+ where none implement a common `@behaviour`.
- **Tolerate:** Single-adapter scenarios, adapters for fundamentally different purposes.
- **Severity:** `info`

### 4.17 Seam Integrity

Calls to behaviour/protocol implementations must go through the seam, not directly.

- **Why:** If code calls `StripeAdapter.charge/2` directly instead of `PaymentProvider.charge/2`, the behaviour is bypassed. Tests can't mock it via Mox, swapping implementations requires finding every call site, and the abstraction provides zero value. The whole point of a seam is that callers use the abstract interface. (Dependency Inversion)
- **Check:** Detect calls that bypass a behaviour seam — calling an implementation module directly when a behaviour-based facade exists for the same operations.
- **Tolerate:** Multi-alias syntax (`alias Foo.{Bar, Baz}`), self-calls (implementation calling itself), test files.
- **Severity:** `warning`

### 4.18 Unbounded External Call

External calls (HTTP, GenServer.call) without explicit timeouts.

- **Why:** Default timeouts (5s for GenServer.call, infinite for some HTTP clients) are almost never correct for production. A stuck external call blocks the caller indefinitely, consuming a process and potentially cascading timeouts through the system. Explicit timeouts document the expected latency contract. (Resilience)
- **Check:** Flag HTTP client calls (Req, Finch, HTTPoison) and GenServer.call without explicit timeout or `:receive_timeout` option.
- **Tolerate:** Local GenServer.call to `__MODULE__` (can't timeout on self).
- **Severity:** `warning`

### 4.19 Missing Telemetry

Context facade modules with many public functions but no telemetry instrumentation.

- **Why:** Without telemetry, you have no observability into how the context is used in production — no latency metrics, no error rates, no throughput data. You're flying blind. Adding `:telemetry.execute` or `:telemetry.span` to public API functions enables dashboards, alerting, and performance tracking without modifying business logic. (Observability)
- **Check:** Flag context-level modules with >5 public functions and no `:telemetry.execute` or `:telemetry.span` calls anywhere in the module.
- **Tolerate:** Internal helper modules, small utility modules.
- **Severity:** `info`

### 4.20 Unprotected External Call

External service calls using bang functions (`HTTPoison.get!`, `Req.post!`) in production code.

- **Why:** Bang functions raise on failure. In production, network errors, timeouts, and service outages are expected — the caller should handle `{:error, _}` gracefully, not crash. The non-bang variant returns ok/error tuples that `case` or `with` can handle. (Error Handling, Resilience)
- **Check:** Flag bang calls to known external IO libraries from non-test code.
- **Tolerate:** Scripts, seeds, migrations, test helpers.
- **Severity:** `warning`

### 4.21 Fat Interface (ISP Violation)

Behaviour implementations with no-op stubs suggest the interface should be split.

- **Why:** If an implementation provides `def callback(_), do: :ok` for half the callbacks, those callbacks don't apply to this implementation. The behaviour is too broad — it should be split into focused interfaces where each implementation uses all callbacks meaningfully. (Interface Segregation Principle)
- **Check:** Flag behaviour implementations where >30% of callbacks are no-op stubs (return `:ok`, `nil`, or match-all with no logic).
- **Tolerate:** `@optional_callbacks` (explicitly optional), transitional implementations during migration.
- **Severity:** `info`

### 4.22 Unused Imports *(compiled)*

Module uses less than 50% of another module's exports — the dependency is wider than necessary.

- **Why:** When a module depends on another but uses only a small fraction of its API, the dependency is wider than it needs to be. This makes the caller harder to understand and creates unnecessary coupling. (Narrow Dependencies, Interface Segregation)
- **Check:** Build compiled call graph. For each module pair, compare functions actually called vs total exports. Flag when <50% of a module's exports (minimum 5) are used.
- **Tolerate:** Modules using a utility module where the unused functions serve other callers.
- **Severity:** `info`

### 4.23 Weak Dependency *(compiled)*

Module depends on another but uses only 1-2 of its many exports.

- **Why:** A dependency on a large module for 1-2 functions creates coupling without proportional benefit. The caller should depend on a more focused interface, or the large module should be split. (Minimal Coupling, Interface Segregation)
- **Check:** Flag when a module uses ≤2 functions from a module with ≥10 exports.
- **Tolerate:** Modules using well-known utility functions (e.g., `String.trim/1`).
- **Severity:** `info`

### 4.24 Protocol/Behaviour Completeness *(compiled)*

Module declares `@behaviour` but doesn't export all required callbacks after macro expansion.

- **Why:** Compiled beam analysis shows the actual exports after all macros have expanded. Missing callbacks will cause runtime failures. This catches cases that the compiler's own check might miss due to macro injection. (Contract Compliance)
- **Check:** For each module with `@behaviour`, verify all required callbacks from `behaviour_info(:callbacks)` are exported.
- **Tolerate:** `@optional_callbacks` in the behaviour definition.
- **Severity:** `warning`

### 4.25 Internal Module Leak *(compiled)*

Internal module (child of a context) called from outside its parent's namespace.

- **Why:** Modules nested under a parent (e.g., `MyApp.Accounts.UserQuery`) are typically internal implementation details. External access bypasses the parent's public API, creating coupling to internals. Compiled data catches macro-injected calls invisible to AST analysis. (Encapsulation, Information Hiding)
- **Check:** Find calls from outside a module's parent namespace to child modules. Exclude widely-used modules (>5 dependents) — they're shared infrastructure.
- **Tolerate:** Shared utility modules, protocol implementations.
- **Severity:** `info`

### 4.26 Phantom Dependency *(compiled)*

Module references another module (in struct patterns, type specs, attributes) but never calls any of its functions.

- **Why:** After compilation, a module references another (e.g., pattern matches on `%Module{}`) but makes zero function calls to it. This may be a leftover from a refactor, an unused alias, or a compile-time-only dependency. Phantom dependencies add noise to the dependency graph and may trigger unnecessary recompilation. (Minimal Dependencies)
- **Check:** Extract all Elixir module atoms from beam abstract code. Compare against modules with actual function calls. Report the difference, classified by reference type (struct, attribute, general).
- **Tolerate:** `@behaviour` declarations (compile-time contracts by design), compile-time macro providers.
- **Severity:** `info`

---

## 5. OTP Process Architecture

### 5A. Process Lifecycle

#### 5.1 All Long-Running Processes Must Be Supervised

No bare `spawn`, `spawn_link`, or unlinked `GenServer.start` for processes that should persist.

- **Why:** Unsupervised processes die silently. No restart, no logging, no visibility in Observer or LiveDashboard. The supervision tree IS the architecture — processes outside it are invisible. (OTP Fundamentals, Error Kernel)
- **Check:** Flag `spawn/1,3`, `spawn_link/1,3`, `GenServer.start/2,3` (the non-link variant), `Agent.start/1,2`, `Task.start/1`, `Task.start_link/1` in non-test code.
- **Tolerate:** Test helpers, `Task.async`/`Task.await` pairs within a single function scope, `spawn_monitor` with explicit `:DOWN` handler.
- **Severity:** `warning`

#### 5.2 No Unnecessary Processes

Modules that wrap pure functions in a GenServer without needing state, concurrency, or fault isolation.

- **Why:** Official Elixir docs: "A GenServer must never be used for code organization purposes." Valid reasons to spawn a process: (1) mutable state, (2) concurrent execution, (3) failure isolation, (4) resource management. If none apply, use a module with functions. Each process costs ~327 words of heap, adds message-copy overhead, and serializes all access. (Official Anti-Patterns, Saša Jurić)
- **Check:** Flag GenServer modules with trivial init state (`%{}`, `[]`, `nil`) and no state mutations across callbacks.
- **Tolerate:** Rate limiters, connection pools, registered processes, framework-required processes (Membrane Bin/Source/Sink/Filter, Broadway, GenStage, Phoenix Channel).
- **Severity:** `info`

#### 5.3 Agent Misuse

Agent used as read-heavy cache where ETS with `read_concurrency: true` would be faster and non-blocking.

- **Why:** Agent serializes ALL access — reads block behind writes. For read-heavy workloads, ETS with `read_concurrency: true` is orders of magnitude faster. Agent also blocks the caller while executing the anonymous function inside the Agent process. (Process Bottleneck)
- **Check:** Flag Agent modules where state is a Map and module name suggests caching (`*Cache*`, `*Store*`, `*Registry*`).
- **Tolerate:** Small-scale Agent in low-concurrency applications, Agent as simple config holder.
- **Severity:** `info`

#### 5.4 No Flat Supervision Trees

Supervisor with too many direct children — group related processes under sub-supervisors with appropriate strategies.

- **Why:** A flat tree with 20 children means one strategy for all. Related processes that should restart together (Registry + DynamicSupervisor) are treated as independent. Sub-supervisors with `:rest_for_one` or `:one_for_all` express process dependencies correctly. (Supervision Design)
- **Check:** Count children in `Supervisor.init` or `Supervisor.start_link`. Flag above threshold.
- **Tolerate:** Small applications with genuinely independent processes.
- **Severity:** `info`

#### 5.6 Default Supervisor Restart Budget

Supervisors relying on default `max_restarts: 3, max_seconds: 5`.

- **Why:** Defaults are rarely correct for production. A connection pool may need higher tolerance for transient failures; a critical service may need stricter limits to fail fast. Explicit values document the operational intent. (Production Readiness)
- **Check:** Flag `Supervisor.start_link` and `Supervisor.init` without explicit `max_restarts`/`max_seconds` options.
- **Tolerate:** Test supervision trees.
- **Severity:** `info`

#### 5.7 Restart Type Mismatch

Restart type must match process lifecycle: `:permanent` for long-running GenServers, `:transient` for tasks.

- **Why:** A `:permanent` task restarts after normal completion — looping forever, hitting max_restarts, and bringing down the supervisor. A `:temporary` GenServer never restarts after crash — the service silently disappears. (OTP Semantics)
- **Check:** Flag Task-like modules with `restart: :permanent`, GenServer modules with `restart: :temporary`.
- **Tolerate:** Intentional one-shot GenServers, intentional persistent task loops.
- **Severity:** `warning`

### 5B. GenServer Hygiene

#### 5.8 No Blocking Work in init/1

GenServer `init/1` must not block on I/O, HTTP, or database queries.

- **Why:** `init/1` blocks the caller (usually a supervisor). A slow init delays the entire supervision tree startup, and a crashing init triggers supervisor restart intensity limits that may bring down the whole tree. (Startup Performance, Supervision Safety)
- **Check:** Flag calls to Repo, HTTP clients, File.read, external services inside init/1 function bodies.
- **Tolerate:** Reading config files, ETS table creation, fast local operations.
- **Severity:** `warning`

#### 5.9 No Blocking Operations in GenServer Callbacks

`handle_call`, `handle_cast`, `handle_info` must not block on I/O.

- **Why:** A blocked callback makes the GenServer unresponsive. Other callers queue up, their GenServer.call timeouts fire (crashing them), and the process appears hung while actually waiting for a slow external call. Offload to Task. (Responsiveness)
- **Check:** Flag calls to known blocking functions (HTTP clients, `Repo.*`, `File.*`) inside handle_call, handle_cast, handle_info callback bodies.
- **Tolerate:** Quick reads, ETS operations, in-memory computations, `handle_continue` (intentional async).
- **Severity:** `warning`

#### 5.11 No receive Inside GenServer Callbacks

`receive` inside a GenServer callback blocks the GenServer from processing its mailbox.

- **Why:** GenServer callbacks should return promptly. A `receive` inside a callback blocks the process from handling other messages — defeating the purpose of a GenServer's ordered mailbox processing. The GenServer is stuck waiting for a specific message while all other messages queue up. (Mailbox Processing)
- **Check:** Flag `receive` blocks inside GenServer callback function bodies.
- **Tolerate:** None — this is always a design error.
- **Severity:** `warning`

#### 5.12 Use handle_continue Instead of send(self()) in init

`send(self(), :init_work)` in `init/1` should be `{:ok, state, {:continue, :init_work}}`.

- **Why:** `send(self())` in init puts a message in the mailbox — but other messages (from processes that already know about this GenServer) may arrive first, causing the process to handle requests before initialization completes. `handle_continue` runs before any other message. (Initialization Order)
- **Check:** Flag `send(self(), _)` inside `init/1`.
- **Tolerate:** Pool/cache patterns where interleaving is intentional (NimblePool does this so the pool stays responsive during worker creation).
- **Severity:** `info`

#### 5.13 Cast Where Call is Needed

`GenServer.cast` used where `GenServer.call` is more appropriate — operations that need confirmation.

- **Why:** Cast is fire-and-forget — the caller never knows if the operation succeeded, failed, or was even received. For operations involving data mutation, status changes, or resource allocation, call provides backpressure (caller blocks), error propagation (caller gets the error), and ordering guarantees. (Reliability)
- **Check:** Flag `GenServer.cast` for messages whose names suggest confirmation is needed (`:create`, `:update`, `:delete`, `:insert`, `:write`, `:save`, `:store`) or that interact with Repo.
- **Tolerate:** Logging, metrics, notifications, broadcast, fire-and-forget cache invalidation.
- **Severity:** `info`

#### 5.14 Silent handle_info Catch-All

`handle_info` catch-all must not swallow messages silently.

- **Why:** A catch-all `def handle_info(_, state), do: {:noreply, state}` silently discards unexpected messages — timer messages from Process.send_after, monitor `:DOWN` signals, TCP socket data, PubSub broadcasts. The process appears healthy while losing data and leaking resources. (Silent Failure)
- **Check:** Flag `handle_info` catch-all clauses whose body doesn't log, re-raise, or return an error.
- **Tolerate:** Explicitly documented catch-alls with a comment explaining the intent.
- **Severity:** `warning`

#### 5.15 Timeout as Polling

GenServer `{:noreply, state, timeout}` return used as a polling mechanism.

- **Why:** The GenServer timeout fires only if no message arrives within the interval — ANY message resets the timer, making polling unreliable. Use `Process.send_after(self(), :poll, interval)` or `:timer.send_interval` for reliable periodic work. (Reliability)
- **Check:** Flag `{:noreply, state, integer}` return patterns in callbacks.
- **Tolerate:** Idle timeouts (intentional inactivity detection is the correct use of GenServer timeout).
- **Severity:** `info`

#### 5.16 Missing terminate/2

GenServers holding resources (connections, file handles, external sessions) should implement `terminate/2`.

- **Why:** Without `terminate/2` and `Process.flag(:trap_exit, true)`, resources leak on process death. Connections stay open, file handles linger, external sessions aren't cleaned up. The supervisor restarts the process but the old resources are orphaned. (Resource Management)
- **Check:** Flag GenServer modules that acquire resources in init (open connections, start external sessions) but don't implement `terminate/2`.
- **Tolerate:** Stateless GenServers, processes whose resources auto-cleanup on process death.
- **Severity:** `info`

#### 5.17 Scattered GenServer.call/cast

GenServer.call/cast should only be used in the defining module's client API, not scattered across the codebase.

- **Why:** The message protocol (atoms and tuples sent via call/cast) is an implementation detail. Other modules should call public API functions (`MyServer.get_status()`) that wrap the GenServer.call internally. This encapsulates the protocol and allows the GenServer to change its message format without updating every caller. (Encapsulation)
- **Check:** Flag `GenServer.call(MyModule, ...)` and `GenServer.cast(MyModule, ...)` from outside `MyModule`.
- **Tolerate:** Test files, supervisor modules.
- **Severity:** `info`

#### 5.18 Synchronous Call Chains

No synchronous `GenServer.call` chains from within callbacks — risk of deadlock.

- **Why:** GenServer.call from handle_call creates a synchronous chain. If the target process calls back (directly or through intermediaries), deadlock. Even without circular calls, chained calls multiply latency and create cascading timeouts when one link is slow. (Deadlock Risk, Latency)
- **Check:** Flag `GenServer.call` inside `handle_call`, `handle_cast`, `handle_info` callbacks.
- **Tolerate:** Calls to processes known to be fast and non-circular (ETS-backed caches).
- **Severity:** `warning`

#### 5.19 Large Messages

Don't send entire `Plug.Conn` or large structs to other processes.

- **Why:** Messages are copied between process heaps in the BEAM (except large binaries which are reference-counted). Sending a full Conn (with body, headers, assigns, private data) copies megabytes per request. Send only the data the receiving process needs. (Memory, Performance)
- **Check:** Flag `send/2`, `GenServer.call/cast` where the message pattern includes Conn-like patterns or the Conn variable is captured by a spawned function.
- **Tolerate:** Small messages, binary references (not copied).
- **Severity:** `warning`

#### 5.37 Missing handle_info

GenServer without any `handle_info/2` clause — unexpected messages pile up in mailbox.

- **Why:** Any message sent to a GenServer that isn't a call or cast arrives via `handle_info/2`. This includes monitor `:DOWN` messages, timer messages from `Process.send_after`, TCP/UDP socket data, and stray messages from linked processes. Without handle_info, these accumulate in the mailbox — the mailbox grows silently until the process is killed by OOM or the scheduler degrades. (Silent Resource Leak)
- **Check:** Flag GenServer modules (not gen_statem which uses handle_event) that define no `handle_info/2` clauses.
- **Tolerate:** gen_statem modules, simple GenServers that genuinely receive no messages (rare — monitors and timers are common).
- **Severity:** `info`

#### 5.38 GenServer.call to Self — Deadlock

`GenServer.call(__MODULE__)` or `GenServer.call(self())` from within a callback causes instant deadlock.

- **Why:** A GenServer processes one message at a time. If `handle_call/3` calls `GenServer.call(__MODULE__, ...)`, the call blocks waiting for a reply — but the GenServer can't process the new call because it's still in the current callback. The process hangs forever, the caller times out, and the supervisor eventually kills it. (Deadlock)
- **Check:** Flag `GenServer.call` targeting `__MODULE__` or `self()` inside callback functions (handle_call, handle_cast, handle_info, handle_continue).
- **Tolerate:** None — this is always a bug. Extract the logic into a private function.
- **Severity:** `warning`

#### 5.39 Brutal Kill

`Process.exit(pid, :kill)` bypasses `terminate/2` — data may be lost.

- **Why:** `:kill` is an untrappable signal — the target process dies immediately without running `terminate/2`. Any in-flight work, open file handles, pending database writes, or external session cleanup is skipped. Use `{:shutdown, reason}` or `:shutdown` instead, which allow the process to clean up gracefully. Reserve `:kill` for truly stuck processes that don't respond to shutdown. (Graceful Shutdown, Data Safety)
- **Check:** Flag `Process.exit(pid, :kill)` in non-test code.
- **Tolerate:** Test cleanup, emergency kill for stuck processes.
- **Severity:** `warning`

#### 5.41 Hardcoded Call Timeout

`GenServer.call` with hardcoded integer timeout instead of a named constant.

- **Why:** Hardcoded timeout values scattered across call sites make it impossible to tune timeouts without finding every occurrence. Different environments (dev with slow startup vs prod with fast paths) and different load conditions may need different values. A module attribute or function parameter makes the value discoverable and adjustable. (Configuration, Maintainability)
- **Check:** Flag `GenServer.call(server, msg, integer_literal)` where the third argument is a hardcoded integer.
- **Tolerate:** Test code, one-off scripts.
- **Severity:** `info`

### 5C. Task Discipline

#### 5.20 Monitor Without Handler

`Process.monitor/1` called without corresponding `:DOWN` handler in the same module.

- **Why:** Monitors send `{:DOWN, ref, :process, pid, reason}` messages to the monitoring process. Without a `handle_info({:DOWN, ...})` clause, these messages pile up in the mailbox, consuming memory and never triggering cleanup. The monitor is effectively dead code. (Silent Leak)
- **Check:** Flag `Process.monitor` in modules that don't have a `handle_info` clause matching `{:DOWN, _, :process, _, _}`.
- **Tolerate:** Modules where :DOWN is handled via a catch-all or in a different module.
- **Severity:** `warning`

#### 5.21 Spawn Without Link or Monitor

`spawn/1` without link or monitor — failures go unnoticed.

- **Why:** A spawned process that crashes without a link or monitor is invisible. Nobody knows it died, no cleanup happens, and the work is silently lost. The caller continues as if the spawned work is running. (Silent Failure)
- **Check:** Flag bare `spawn/1,3` without corresponding `Process.monitor` or `Process.link` in the same function.
- **Tolerate:** Test helpers, diagnostic/debugging code.
- **Severity:** `warning`

#### 5.22 Task.async Without Task.await

`Task.async` creates a linked task that MUST be awaited — the result is otherwise lost.

- **Why:** `Task.async` links the task to the caller and sets up a protocol expecting `Task.await` or `Task.yield`. Not awaiting means: (1) the task result is lost, (2) the linked task may crash the caller unexpectedly, (3) the task ref leaks. Use `Task.Supervisor.start_child` for fire-and-forget. (Task Protocol)
- **Check:** Flag `Task.async` calls in functions that don't call `Task.await`, `Task.yield`, or `Task.yield_many`.
- **Tolerate:** Results handled via `handle_info` in GenServers (the task sends a message on completion).
- **Severity:** `warning`

#### 5.23 Unsupervised Task

`Task.start/1` or `Task.start_link/1` in production code instead of `Task.Supervisor`.

- **Why:** Bare `Task.start` creates a process outside any supervisor. If it crashes, nobody knows. `Task.Supervisor.start_child` creates the task under a supervisor with proper error handling, restart strategies, and shutdown behaviour. (Supervision)
- **Check:** Flag `Task.start/1` and `Task.start_link/1` in non-test code.
- **Tolerate:** Test code, scripts, interactive sessions.
- **Severity:** `info`

### 5D. ETS Patterns

#### 5.27 ETS as Message Bus

ETS used as a communication channel between processes instead of message passing.

- **Why:** ETS polling is inefficient (busy-wait or timer-based) and loses the ordering guarantees of message passing. Processes should communicate via `send`/`receive`, GenServer calls, PubSub, or Registry dispatch. ETS is a shared data store, not a message bus. (OTP Message Passing)
- **Check:** Flag patterns where one process writes to ETS and another process polls it in a loop.
- **Tolerate:** ETS as shared read cache (write-once-read-many), ETS for metrics counters.
- **Severity:** `info`

#### 5.28 ETS Without Heir

Critical ETS tables should configure `:heir` for survival across process restarts.

- **Why:** When the owning process dies, its ETS tables are deleted — all cached data is lost. If a supervisor restarts the process, the new instance starts with an empty table. Configuring `:heir` transfers ownership to another process instead of deleting the table. (Data Persistence)
- **Check:** Flag `:named_table` ETS creation without `:heir` option in production code.
- **Tolerate:** Disposable caches that are cheap to rebuild, test tables.
- **Severity:** `info`

#### 5.40 ETS Ownership Leak

ETS table created in GenServer's `init/1` without cleanup in `terminate/2`.

- **Why:** When the owning process dies and restarts, creating a new `:named_table` with the same name may crash because the old table still exists momentarily (race condition with ETS cleanup). Explicit deletion in `terminate/2` or configuring `:heir` prevents this. (Resource Management, Restart Safety)
- **Check:** Flag GenServer modules that call `:ets.new` in init but don't implement `terminate/2` or configure `:heir`.
- **Tolerate:** Non-named tables (no name collision risk), tables with heir configuration.
- **Severity:** `info`

### 5E. Process Naming & Registry

#### 5.24 Dynamic Atom Names

`String.to_atom/1` called — atoms are never garbage collected.

- **Why:** Atoms live in a global table with a hard limit (default ~1,048,576). Anything that converts user input or growing strings to atoms is a memory leak: enough unique inputs and the VM crashes with "not enough atom space." Use `String.to_existing_atom/1` (fails safely) or explicit atom mapping. (Memory Safety, VM Stability)
- **Check:** Flag `String.to_atom/1` in non-test code.
- **Tolerate:** Compile-time atom creation, `String.to_existing_atom`, `Module.concat` (different mechanism).
- **Severity:** `info`

#### 5.25 Custom Registry Reinvention

Custom process lookup maps reinventing what Elixir's `Registry` module already provides.

- **Why:** `Registry` handles cleanup automatically when registered processes die, supports both unique and duplicate keys, and is BEAM-optimized. A custom GenServer maintaining a `Map` of pid→name loses automatic cleanup, becomes a serialization bottleneck, and accumulates dead PIDs. (Standard Library, Reliability)
- **Check:** Flag GenServer modules that maintain a Map of pid→name or name→pid with manual insert/delete operations.
- **Tolerate:** Specialized lookup structures with semantics different from Registry.
- **Severity:** `info`

#### 5.26 Global Registration

`:global` registration for local-only processes.

- **Why:** `:global` uses distributed consensus (leader election via `:global` module). For single-node process discovery, `Registry` is vastly simpler, faster, and doesn't have the edge cases of distributed registration (split-brain, network partitions). (Performance, Simplicity)
- **Check:** Flag `:global` registration in non-distributed applications.
- **Tolerate:** Applications explicitly using distributed Elixir (`Node.connect`, `Horde`).
- **Severity:** `info`

#### 5.29 Singleton Bottleneck

Named GenServer handling entity-keyed requests — all requests serialized through one process.

- **Why:** A named GenServer that dispatches by entity ID (user_id, order_id) serializes all requests through one process. If you have 10,000 users, their requests queue behind each other. Use DynamicSupervisor + Registry for per-entity processes — each entity gets its own process, and requests are parallel. (Scalability)
- **Check:** Flag named GenServer modules where `handle_call`/`handle_cast` pattern-matches on an ID-like field in the message to dispatch different entities.
- **Tolerate:** Low-throughput coordination processes, rate limiters (serialization is the point).
- **Severity:** `info`

#### 5.33 Unnamed Singleton

GenServer whose public API uses `__MODULE__` as the server target but `start_link` doesn't register the name.

- **Why:** If the public API calls `GenServer.call(__MODULE__, ...)` but `start_link` doesn't pass `name: __MODULE__`, the calls will fail with "no process associated with the given name" — even though the process IS running (just not registered). (Configuration Bug)
- **Check:** Flag GenServer modules where public functions reference `__MODULE__` as the server target but `start_link` doesn't pass `name: __MODULE__` or an equivalent registration.
- **Tolerate:** Modules where the name is passed dynamically via options.
- **Severity:** `info`

#### 5.36 Stale PID Reference

PIDs stored in process state or ETS without `Process.monitor` — become stale after process restart.

- **Why:** PIDs reference a specific process incarnation. When that process dies (and potentially restarts with a new PID), the stored reference still points to the old dead process. Messages sent to it are silently dropped, `GenServer.call` raises an `:exit`. Without monitoring, the storing process never learns the referenced process died — leading to silent message loss and growing stale entries. Production systems (Supavisor, Finch, db_connection) always monitor PIDs they store. (Stale Reference, Silent Failure)
- **Check:** Flag `:ets.insert` with pid-like variables or state map updates with pid keys without corresponding `Process.monitor` or `Process.link` in the same function.
- **Tolerate:** PIDs managed by Registry (auto-cleanup), short-lived references in synchronous operations.
- **Severity:** `info`

### 5F. Process State & Safety

#### 5.30 Process.sleep in Production

`Process.sleep/1` blocks the calling process for the specified duration.

- **Why:** Sleep blocks the entire process — in production, this means unresponsive GenServers, delayed request handling, and wasted scheduler time. For periodic work, use `Process.send_after` or `:timer.send_interval`. For rate limiting, use token buckets or GenServer state. (Performance, Responsiveness)
- **Check:** Flag `Process.sleep` in non-test, non-script files.
- **Tolerate:** Test files, seed scripts, deliberate rate limiting with documented reason.
- **Severity:** `info`

#### 5.31 Unbounded State

GenServer accumulating unbounded data in process state.

- **Why:** Process state lives on the process heap. Unbounded accumulation (event logs, request history, cache without eviction, append-only lists) eventually causes out-of-memory. The BEAM can't garbage-collect live data — it's all referenced. Use ETS for growing datasets, or implement eviction. (Memory Safety)
- **Check:** Heuristic — flag GenServer state that grows via `[new | state.list]` or `Map.put` without corresponding cleanup or size limit.
- **Tolerate:** Bounded collections with explicit size limits, ETS-backed state.
- **Severity:** `info`

#### 5.32 Process Dictionary

`Process.put/get` — hidden mutable state that doesn't appear in function signatures.

- **Why:** The process dictionary is invisible mutable state. It doesn't appear in `handle_call` arguments or return values, can't be inspected via `:sys.get_state`, can't be tested without running specific process setup, and survives across callback invocations without being in the state parameter. (Testability, Explicitness)
- **Check:** Flag `Process.put/2` and `Process.get/1,2` in non-infrastructure code.
- **Tolerate:** Logger metadata, OpenTelemetry context, connection pool ownership tracking.
- **Severity:** `info`

#### 5.34 Unsafe Production Tracing

`:dbg` and `:erlang.trace` used without safety limits in production code.

- **Why:** `:dbg` without message limits can produce gigabytes of trace output in seconds on a production system, overwhelming logging infrastructure and filling disks. Use Rexbug or `:recon_trace` which have built-in safety limits (max messages, duration timeout, rate limiting). (Production Safety)
- **Check:** Flag `:dbg.tpl`, `:dbg.p`, `:erlang.trace` in non-test code.
- **Tolerate:** Test code, developer tooling modules, modules explicitly named "debug" or "trace".
- **Severity:** `info`

#### 5.35 GenStage No Demand

GenStage consumer subscription without explicit `max_demand`/`min_demand`.

- **Why:** Default demand settings may not match the producer's capacity. Explicit values document the expected throughput contract and prevent overwhelming slow consumers with too many events at once. (Backpressure, Configuration)
- **Check:** Flag GenStage consumer `subscribe_to` or `subscribe` calls without `max_demand`/`min_demand` options.
- **Tolerate:** Simple producer-consumer pairs in low-throughput scenarios.
- **Severity:** `info`

#### 5.42 Sequential Where Parallel

Sequential collection processing with I/O in the callback — candidate for `Task.async_stream`.

- **Why:** `Enum.map/each/flat_map` processing where each iteration performs I/O (HTTP, database, file) blocks sequentially. For N items with T seconds of I/O each, sequential takes N*T wall-clock time. `Task.async_stream` runs iterations in parallel, reducing wall-clock time to approximately T. Also detects sequential independent variable bindings that could use `Task.async`. (Performance, Parallelism)
- **Check:** Flag `Enum.map/each/flat_map`, `Stream.map/each/flat_map`, and `for` comprehensions where the callback body calls known I/O modules (Repo, HTTPoison, Req, Finch, Tesla, File, GenServer, Mailer, etc.). Also flag consecutive independent variable bindings that each perform I/O and don't depend on each other.
- **Tolerate:** Test files, callbacks that must run in order, rate-limited external services, already-parallel code (Task.async_stream).
- **Severity:** `info`

---

## 6. Module Quality

### 6A. Size & Complexity

#### 6.1 Module Cohesion

Module with too many public functions — suggests mixed responsibilities.

- **Why:** A module with 30 public functions is doing too many things. It's hard to understand (which functions relate to each other?), hard to test (large setup for each test context), and hard to maintain (changes cascade through unrelated functions). Split into focused modules. (Single Responsibility)
- **Check:** Count public `def` functions (excluding framework callbacks). Flag above threshold.
- **Tolerate:** Context facade modules (designed to have many public functions as the domain's API surface), macro-generated functions.
- **Severity:** `info` / `warning`

#### 6.2 Function Complexity

High cyclomatic complexity or excessive arity.

- **Why:** Functions with many branches (case, cond, if, with — each adding a path through the code) are hard to test exhaustively. High arity (>5 parameters) signals too many responsibilities packed into one function. Both indicate the function should be decomposed. (Complexity, Testability)
- **Check:** Compute cyclomatic complexity per function (count case/cond/if/with branches). Flag above threshold (default: 9). Also flag arity > 5.
- **Tolerate:** Pattern-matching dispatch across multiple clauses (each clause is simple, the complexity is in the dispatch).
- **Severity:** `info`

#### 6.3 Struct Field Count

Structs with too many fields suggest the data model should be decomposed.

- **Why:** A struct with 25 fields is hard to construct correctly, hard to pattern-match partially, and hard to maintain. Nested structs (Address, Metadata, Settings) break it into focused shapes that each have their own validation and documentation. (Data Design)
- **Check:** Count `defstruct` fields. Flag above threshold.
- **Tolerate:** Ecto schemas (may legitimately map wide database tables).
- **Severity:** `info` / `warning`

#### 6.4 Module Length

File length as an architecture signal — long files do too much.

- **Why:** Files over 500 lines are hard to navigate and typically contain mixed concerns. Over 1000 lines almost certainly have multiple responsibilities that should be in separate modules. (Readability, SRP)
- **Check:** Count source lines per file. 500 = warning, 1000 = error.
- **Tolerate:** Generated files, comprehensive test files with many test cases.
- **Severity:** `warning` / `error`

#### 6.5 Function Fan-Out

Individual functions depending on too many distinct modules.

- **Why:** A function that calls 10 different modules is an orchestration point that's hard to test (many dependencies to mock) and hard to understand (too many concepts in one place). (Coupling)
- **Check:** Count distinct module references per function using FunctionGraph. Flag above threshold.
- **Tolerate:** Facade functions that intentionally coordinate across modules.
- **Severity:** `info`

#### 6.12 Responsibility Clustering

Module has independent function clusters suggesting multiple responsibilities.

- **Why:** If a module's public functions form 2+ disconnected clusters (user_* functions never call order_* functions and vice versa), the module has multiple responsibilities that happen to share a file. They should be separated into focused modules. (Single Responsibility, Cohesion)
- **Check:** Build an intra-module call graph of public→private function calls. Detect disconnected components.
- **Tolerate:** Small modules with few functions, thin facade modules.
- **Severity:** `info`

### 6B. Naming & Design

#### 6.6 Boolean Flag Arguments

Functions with boolean parameters — `do_thing(true)` is opaque at the call site.

- **Why:** `process_order(order, true)` is unreadable at the call site. The reader must look up the function signature to understand what `true` means. `process_order(order, validate: true)` (keyword option) or `process_and_validate_order(order)` (separate function) communicates intent. (Readability)
- **Check:** Flag functions where a boolean argument controls an `if` branch inside the body — the boolean is a hidden dispatch mechanism.
- **Tolerate:** Simple predicate wrappers, internal helpers not exposed as public API.
- **Severity:** `info`

#### 6.7 Pretentious Names

Module names containing Manager, Helper, Util, Service, Handler hide what the module actually does.

- **Why:** These suffixes describe the relationship to other code, not what the module does. "OrderHelper" could contain anything — the name provides zero information. "OrderPriceCalculator" or "OrderValidator" describes the responsibility. (Naming)
- **Check:** Flag module names ending in Manager, Helper, Util, Utils, Service, Handler, Base.
- **Tolerate:** Framework-conventional names where the suffix has a specific meaning (EventHandler in Broadway, ChannelHandler in Phoenix).
- **Severity:** `info`

#### 6.8 Distance from Main Sequence

Robert C. Martin's package metrics (Ca/Ce/I/A/D) — modules far from the main sequence are problematic.

- **Why:** A module that many others depend on (high stability, low instability) but has no abstractions (no behaviours, no protocols — low abstractness) is in the "Zone of Pain": concrete and stable, meaning it's hard to change without breaking many dependents. The main sequence is the optimal line where abstractness and instability balance. (Robert C. Martin Metrics)
- **Check:** Compute Ca (afferent coupling — who depends on me), Ce (efferent coupling — who do I depend on), I (instability = Ce/(Ca+Ce)), A (abstractness = abstract elements / total elements), D (distance = |A + I - 1|). Flag modules with D > threshold.
- **Tolerate:** Small utility modules, configuration modules.
- **Severity:** `info`

#### 6.17 Nesting Depth

Deeply nested control flow (>4 levels of case/with/if/cond) — extract functions to flatten.

- **Why:** Each nesting level (case inside with inside if) adds a branch the reader must track mentally. Beyond 3-4 levels, the code becomes a maze that's hard to follow and nearly impossible to test all paths. Extract inner branches into named private functions — each becomes independently readable and testable. (Readability, Testability)
- **Check:** Walk AST counting nesting depth of control flow constructs (case, cond, if, with, try). Flag functions exceeding the threshold.
- **Tolerate:** Pattern matching in function heads (not counted as nesting).
- **Severity:** `info`

#### 6.19 If/Else for Structural Dispatch

`if/else` used to dispatch on data shape or type instead of multi-clause functions or case.

- **Why:** Elixir's multi-clause functions and `case` expressions handle structural dispatch more clearly than `if/else` chains. Pattern matching is exhaustive (the compiler warns on missing clauses), self-documenting (each clause shows the shape it handles), and extensible (add a clause, don't modify a condition). `if/else` hides the dispatch inside a boolean expression and doesn't compose. (Idiomatic Elixir, Elixir Skill Rule 1)
- **Check:** Flag `if is_map(x) do ... else ... end`, `if is_nil(x) do ... else ... end`, and similar type-guard if/else patterns where both branches return values. Also flags `if x != nil do ... else ... end`.
- **Tolerate:** `if` without `else` (side-effect only — idiomatic), simple boolean conditions that aren't structural dispatch.
- **Severity:** `info`

### 6C. Error Handling

#### 6.9 Rescue Swallows Error

Bare rescue clauses that swallow errors silently — catch everything, do nothing useful with it.

- **Why:** Elixir's error handling philosophy is "let it crash" for processes (supervisors restart them) and ok/error tuples for function-level errors. A bare rescue that swallows exceptions combines the worst of both worlds: the error is not propagated (so callers can't handle it), the process doesn't crash (so the supervisor doesn't restart it), and no log is produced (so nobody knows it happened). Silent failures accumulate into mysterious behaviour that's impossible to debug. (Error Visibility, Let It Crash)
- **Check:** Flag rescue clauses that catch wildcards (`_` or `_e`) and don't log, reraise, or return `{:error, _}`.
- **Tolerate:** Rescue clauses that log the error, return `{:error, reason}`, or reraise.
- **Severity:** `warning`

#### 6.10 Raise in Non-Bang Function

Non-bang functions should return ok/error tuples, not raise exceptions.

- **Why:** Elixir convention: `fetch/1` returns `{:ok, _}` or `{:error, _}`, `fetch!/1` raises. A non-bang function that raises breaks this convention — callers must add try/rescue when they expected pattern matching on the return value. This defeats the ok/error pattern and makes error handling inconsistent. (API Convention, Elixir Skill Rule 2)
- **Check:** Flag public functions not ending in `!` that contain `raise` without a surrounding `rescue` block.
- **Tolerate:** Framework callbacks where raising is the "let it crash" convention (handle_init, handle_pad_added, handle_info, handle_call, terminate — whitelisted), setup/validation functions (`init`, `validate!`).
- **Severity:** `warning`

#### 6.11 Inconsistent Error Shape

Module mixes ok/error tuples with raises, nils, and bare returns across its public API.

- **Why:** A module where `fetch/1` returns `{:ok, _}`, `get/1` returns nil, and `create/1` raises has three different error conventions. Callers must read every function's implementation to know how to handle failure. This multiplies the mental overhead of using the module. Pick one style per module. (Consistency, Predictability)
- **Check:** Classify each public function's error style (ok/error, raises, returns_nil, bare). Flag modules with 3+ distinct styles.
- **Tolerate:** Bang/non-bang pairs (intentional — the module provides both), modules with only 1-2 public functions.
- **Severity:** `info`

#### 6.14 Try/Rescue for Expected Failures

`try/rescue` wrapping a bang function where the non-bang variant already returns ok/error tuples.

- **Why:** `try do Repo.get!(User, id) rescue Ecto.NoResultsError -> nil end` is an exception round-trip — raising an exception then immediately converting it back into a value. `Repo.get(User, id)` already returns nil without the exception overhead. The try/rescue pattern also catches more than intended: a bug in the try body that raises the same exception type is silently swallowed. (Idiomatic Elixir, Performance, Elixir Skill Rule 2)
- **Check:** Flag try/rescue blocks that contain bang function calls (`get!`, `decode!`, `insert!`) and catch specific exceptions.
- **Tolerate:** Test code, cases where no non-bang alternative exists.
- **Severity:** `warning`

#### 6.15 Bang in Ok/Error Function

Functions returning ok/error tuples should not call bang functions that can raise.

- **Why:** When a function establishes an ok/error contract (returns `{:ok, _}` or `{:error, _}`), callers expect failures to come back as `{:error, reason}`, not as raised exceptions. A bang call inside this function breaks that contract — the caller's `case` or `with` never sees the error branch because the bang raises before the function can return `{:error, _}`. The caller must add a try/rescue, defeating the purpose of the ok/error API. (Contract Violation)
- **Check:** Flag public functions that return ok/error tuples AND contain bang calls to non-stdlib modules.
- **Tolerate:** `init`, `start_link` (setup contexts), `struct!` (programmer error, not runtime failure), seed/migration files.
- **Severity:** `info`

#### 6.16 Missing Rescue at System Boundary

System boundary calls need rescue/catch, not just ok/error — the boundary IS where exceptions are expected.

- **Why:** Two specific patterns require exception handling (not ok/error):
  1. `GenServer.call(variable_pid, msg)` — raises an `:exit` (not an exception) when the target process has died. `rescue` doesn't catch exits; you need `catch :exit`. LiveView, Oban, and db_connection all use this pattern.
  2. `:erlang.binary_to_term(data)` on untrusted input — raises `ArgumentError` on malformed data. This is a system boundary where the input is external and may be anything.
- **Check:** Flag `GenServer.call(variable, ...)` without `catch :exit`, and `:erlang.binary_to_term` without `rescue`. Skip calls to `__MODULE__` (can't die during call).
- **Tolerate:** Calls to atom-named servers (known to be registered), calls inside supervised processes where crash-and-restart is acceptable.
- **Severity:** `info` / `warning`

#### 6.18 Exception Laundering

Rescue catches one exception type but raises a different one — original stacktrace is lost.

- **Why:** When a rescue clause catches ExceptionA but raises ExceptionB, the original stacktrace and error context are lost. Debugging becomes harder because the error reported at the surface doesn't match the root cause. If you need to wrap exceptions, use `reraise/2` to preserve the stacktrace, or return `{:error, reason}` to let the caller decide. (Debuggability, Stacktrace Preservation)
- **Check:** Flag rescue clauses that catch a specific exception type AND raise a different exception type (not `reraise`).
- **Tolerate:** Rescue clauses using `reraise` (preserves stacktrace), rescue clauses returning ok/error tuples.
- **Severity:** `info`

### 6D. Recursion

#### 6.20 Non-Tail Recursion

Recursive function where the call is not in tail position — risks stack overflow on large input.

- **Why:** Tail-call optimization (TCO) reuses the stack frame when the recursive call is the last expression — constant memory regardless of depth. When the call is NOT last (e.g., `[head | recurse(tail)]` — the cons operation happens after the recursive return), each call adds a stack frame. On large input, this overflows the stack. (Stack Safety, Elixir Skill: "Operations after the call break TCO")
- **Check:** Flag recursive functions where the self-call appears inside a cons `[_ | recurse(_)]`, append `_ ++ recurse(_)`, or arithmetic `_ + recurse(_)`.
- **Tolerate:** Tree traversal (inherently non-tail but bounded by tree depth, not list length).
- **Severity:** `info`

#### 6.21 Unnecessary Manual List Recursion

`[head | tail]` + `[]` base case pattern where Enum functions would suffice.

- **Why:** Elixir's Enum module handles list iteration with `map`, `reduce`, `filter`, `flat_map`, and 50+ other functions. Manual recursion with `[head | tail]` is more code, harder to read, and easy to get wrong (non-tail position, missing base case). Use recursion only for tree traversal, early termination with complex state, or when multiple accumulators are needed. (Idiomatic Elixir, Elixir Skill Rule 6)
- **Check:** Flag multi-clause functions where one clause matches `[head | tail]` and calls itself with tail, and another clause matches `[]` as the base case.
- **Tolerate:** Tree/graph traversal (recursion IS the right tool), multi-accumulator patterns, functions that need early termination with complex conditions.
- **Severity:** `info`

#### 6.22 Broken Tail-Call Optimization

Recursive function appears tail-recursive but TCO is silently defeated by surrounding code.

- **Why:** Three patterns break TCO without changing the apparent structure of the recursive function:
  1. `try/rescue/catch` wrapping the recursive call — the BEAM must keep the stack frame to unwind on exception
  2. Pipe after the call — `recurse(t, acc) |> IO.inspect()` runs the pipe operation after return
  3. Binary operation after the call — `recurse(t, acc) <> suffix` runs concatenation after return
  
  The function works perfectly on small input (the stack is big enough) but crashes with stack overflow on large data. The developer thinks they've written a tail-recursive function because it has an accumulator. (Silent Stack Overflow, Elixir Skill: "try/rescue/catch blocks prevent TCO")
- **Check:** Flag recursive functions where the self-call is inside a try/rescue/catch block, piped into another function, or used as an operand in a binary expression.
- **Tolerate:** Non-recursive functions (no self-call to break).
- **Severity:** `warning`

#### 6.23 Unbounded Recursion

Recursive function without depth guard or finite base case — stack overflow risk on large/malicious input.

- **Why:** Non-tail recursive functions consume one stack frame per call. Without a depth guard (e.g., `when depth < @max_depth`) or a guaranteed finite base case (matching `[]` or `0`), the recursion depth depends entirely on the input. If the input comes from outside the system (user data, API response, file content), a malicious or malformed input can crash the process with a stack overflow. (Input Safety, Defensive Programming)
- **Check:** Flag non-tail recursive functions that lack: (1) a finite base case matching `[]` or `0`, (2) a depth guard parameter with numeric comparison, (3) struct pattern matching (tree walk — bounded by known structure). Only applies to functions that ARE recursive and NOT tail-recursive.
- **Tolerate:** Tail-recursive functions (safe at any depth), list recursion with `[]` base case (bounded by input length), tree walks with struct patterns.
- **Severity:** `info`

### 6E. Compiled Analysis

#### 6.24 Dead Public Function *(compiled)*

Public function exported but never called from outside the module.

- **Why:** Public functions are part of a module's API contract. An exported function nobody calls is dead weight — it increases the API surface, survives refactors that should have removed it, and misleads developers. (Dead Code Elimination, API Clarity)
- **Check:** Build compiled call graph from beam files. Find exported functions with zero external callers. Exclude framework callbacks (init, handle_call, mount, render, etc.) and behaviour callbacks.
- **Tolerate:** Library API functions called by external consumers, dynamically called functions (apply/3, protocol dispatch).
- **Severity:** `info`

#### 6.25 Transitively Dead Function *(compiled)*

Function only called from dead functions — removing the dead callers would make this unreachable.

- **Why:** This function has callers, but every caller is itself dead code (rule 6.24). The entire call chain is dead. (Transitive Dead Code, Call Graph Analysis)
- **Check:** Walk outward from dead roots in the compiled call graph. If all callers of a function are dead, the function is transitively dead. Only checks project modules, not stdlib.
- **Tolerate:** Same as 6.24.
- **Severity:** `info`

#### 6.26 Oversized API Surface *(compiled)*

Module exports many functions but less than 25% are called by external modules.

- **Why:** A module with many exports but few external callers has an oversized public API. Every exported function is a contract. Functions only used internally should be `defp`. (Minimal API Surface, Encapsulation)
- **Check:** Count external callers per exported function. Flag modules with ≥8 exports where <25% are used externally.
- **Tolerate:** Library modules designed for external consumption, utility modules with intentionally broad APIs.
- **Severity:** `info`

#### 6.27 Non-Exhaustive Public API *(compiled)*

Public function has multiple clause patterns but no catch-all — crashes with FunctionClauseError on unexpected input.

- **Why:** A public API function pattern-matching on specific shapes without a fallback clause will crash if called with unexpected input. For internal dispatch this is fine (let it crash), but public API functions should handle all inputs gracefully or document their constraints. (API Robustness, Defensive Programming)
- **Check:** Extract function clauses from beam abstract code. Flag exported functions with ≥2 clauses where no clause is a catch-all (all args are variables with no guards).
- **Tolerate:** Functions where the restricted input set is by design (dispatch tables, type-specific handlers), internal functions that are public for technical reasons.
- **Severity:** `info`

#### 6.28 Inconsistent API Return Shapes *(compiled)*

Public function returns different shapes from different clauses.

- **Why:** A function returning `{:ok, _}` from one clause and `:ok` from another forces callers to handle all possible shapes. Consistent return shapes make the API predictable and pattern-matchable. (API Consistency, Contract Clarity)
- **Check:** Classify return expressions from each clause in beam abstract code. Flag functions where clauses return different shape categories. Excludes `{:ok, _} | {:error, _}` which is a valid standard pattern.
- **Tolerate:** Functions where varying return shapes are intentional and documented with `@spec`.
- **Severity:** `warning`

#### 6.29 Stub Function

Function body is a placeholder that will fail at runtime — `raise "not implemented"`, TODO, or similar.

- **Why:** Stub functions are useful during development but dangerous in production. They crash or silently misbehave when the code path is reached. (Production Readiness, Code Completeness)
- **Check:** Flag function bodies containing: `raise "not implemented"`, `raise "TODO"`, `IO.warn("not implemented")`, or returning `:not_implemented`. Skip test files.
- **Tolerate:** Test helpers, intentionally unsupported behaviour callbacks with `@doc` explaining why.
- **Severity:** `warning`

#### 6.30 Degenerate Function *(compiled)*

Public function always raises or returns a fixed value regardless of input — likely a stub surviving macro expansion.

- **Why:** After all macros expand, this function's compiled body is degenerate — it either always raises or every clause returns the same fixed atom. This catches stubs injected by macros that aren't visible in source code. (Post-Expansion Stub Detection)
- **Check:** Analyze beam abstract code. Flag exported functions where all clauses either raise or return the same literal. Exclude OTP callbacks (init, terminate, etc.) and single-clause `:ok` returns (normal side-effect functions).
- **Tolerate:** OTP callbacks, side-effect functions that legitimately return `:ok`.
- **Severity:** `info` (warning for "not implemented" raises)

#### 6.31 Lookup Table Candidate *(compiled)*

Function is a pure literal-to-literal mapping — equivalent to a Map lookup.

- **Why:** Multi-clause functions that map literal values to literal values with no computation are functionally equivalent to `Map.fetch!/2`. Replacing with a module attribute map is more concise, self-documenting, and can be more efficient (O(log n) map lookup vs O(n) clause matching for large tables). The data becomes extractable for documentation or serialization. (Data vs Code, Clarity)
- **Check:** Analyze beam abstract code. Flag functions where ≥3 clauses all have literal-only patterns (atoms, integers, strings, tuples of literals) and literal-only return values. Also detects single-clause functions with a `case` body that is a lookup table.
- **Tolerate:** Small dispatch tables (2 clauses), functions expected to gain guards or logic later.
- **Severity:** `info`

#### 6.32 Buried try/rescue

try/rescue block buried inside an anonymous function, Enum callback, or Task callback — should be extracted to a named function.

- **Why:** A try/rescue hidden inside a lambda or Enum.map callback obscures the error handling intent. The rescue clause silently converts exceptions to fallback values, making bugs invisible. Extracting to a named function (like `safe_process/1`) makes the fault isolation visible at the call site and documents that exceptions are expected. Named functions are also testable independently and reusable. (Clarity, Error Handling Visibility, Testability)
- **Check:** Flag try/rescue blocks inside: `Enum.map/flat_map/each/reduce` callbacks, `Task.async/async_stream` callbacks, or standalone `fn -> ... end` expressions. Does not flag try/rescue in named private functions (correct pattern) or try/after (cleanup pattern).
- **Tolerate:** try/rescue in named private functions — this IS the correct pattern. The rule specifically targets the anonymous/inline form.
- **Severity:** `info`

---

## 7. Test Architecture

#### 7.1 Test Mirrors Source

Test file structure should mirror source structure (`lib/foo/bar.ex` → `test/foo/bar_test.exs`).

- **Why:** The mirroring convention makes test locations predictable: any developer can guess where to find tests for a module without searching. When source files lack mirrored tests, the missing files are invisible to coverage tools, hard to find for new contributors, and gradually the test suite stops covering whole sub-trees of the codebase. (Convention, Discoverability)
- **Check:** Project-level: compare lib/ structure with test/ structure. Flag source files without corresponding test files at the mirrored path.
- **Tolerate:** `application.ex`, `*_web.ex`, `endpoint.ex`, `router.ex`, `telemetry.ex`, `repo.ex`, `mailer.ex`, mix tasks.
- **Severity:** `info`

#### 7.2 Repo in Tests

Tests should use context APIs, not direct Repo calls for setting up or asserting data.

- **Why:** Direct `Repo.insert` calls in tests couple tests to the database schema. When the schema changes, both the context and the tests break independently. Testing through the public context API means tests break only when the API contract changes — exactly when they should. (Test Coupling)
- **Check:** Flag `Repo.insert`, `Repo.update`, `Repo.delete`, `Repo.get` in test files.
- **Tolerate:** DataCase setup, test support/factory modules, seed data, cleanup operations.
- **Severity:** `info`

#### 7.3 Mocks Need Behaviours

Every `Mox.defmock` must reference a behaviour module with `@callback` declarations.

- **Why:** Mox verifies that mocks implement the same callbacks as the behaviour — a compile-time guarantee that the mock's API matches the real implementation. Without a behaviour, the mock is unverified: you could mock a function that doesn't exist on the real module, and the test would pass while the production code crashes. (Contract Testing, Compile-Time Safety)
- **Check:** Flag `Mox.defmock` calls where the `for:` target module doesn't declare `@callback`.
- **Tolerate:** None — this is always a correctness issue.
- **Severity:** `warning`

#### 7.4 Async Eligibility

Test files should declare `async: true` when eligible.

- **Why:** Async tests run in parallel, dramatically speeding up the test suite. Tests that don't modify global state can safely run async. Common blockers: named ETS tables, `Application.put_env`, named GenServers, Mox in global mode. All of these have async-safe alternatives. (Test Performance)
- **Check:** Flag test files without `async: true` that don't reference global state modifiers.
- **Tolerate:** Tests using `set_mox_global`, named ETS tables, `Application.put_env`.
- **Severity:** `info`

#### 7.5 Sleep in Tests

`Process.sleep` in tests leads to flaky and slow tests.

- **Why:** Sleep-based tests are slow (always wait the full duration even when the operation completes in 1ms) and flaky (may not wait long enough under CI load). Use `assert_receive` with explicit timeouts for message-based assertions — it returns immediately when the message arrives and fails with a clear error after timeout. (Test Reliability, Test Performance)
- **Check:** Flag `Process.sleep` in test files.
- **Tolerate:** None — `assert_receive`, polling with `eventually`, or explicit synchronization is always better.
- **Severity:** `warning`

#### 7.8 Test Naming

Test modules should be named `*Test` in `*_test.exs` files.

- **Why:** ExUnit discovers tests by filename convention (`*_test.exs`). A mismatched module name (module `MyApp.FooSpec` in `foo_test.exs`) causes confusion when running specific tests, and some tools assume the convention holds. (Convention)
- **Check:** Flag test modules where the module name doesn't match the `*Test` convention for the filename.
- **Tolerate:** Test support modules, shared test helpers.
- **Severity:** `warning`

#### 7.9 No Assertion

Tests must contain at least one assertion.

- **Why:** A test without any assertion always passes — it tests nothing. It gives false confidence that the code works when it's actually never checked. Even compilation-only tests should use `assert` on the result. (Test Validity)
- **Check:** Flag test blocks without `assert`, `refute`, `assert_receive`, `assert_raise`, `assert_broadcast`, `assert_push`, or other assertion macros.
- **Tolerate:** Tests that verify side effects exclusively via Mox expectations (with `verify_on_exit!`).
- **Severity:** `warning`

#### 7.10 Trivial Assertion

Tests with trivial assertions like `assert true`, `assert 1 == 1`, `assert :ok`.

- **Why:** Trivial assertions always pass regardless of what the code does — they're placeholders that were never replaced with real checks. They provide the illusion of test coverage without actually testing anything. (Test Validity)
- **Check:** Flag `assert true`, `assert 1 == 1`, `assert :ok`, `assert nil != nil`, and similar constant assertions.
- **Tolerate:** None — replace with meaningful assertions or delete the test.
- **Severity:** `warning`

#### 7.11 Long Setup

Setup blocks with >400 AST nodes suggest over-coupled test infrastructure.

- **Why:** Large setup blocks create many implicit dependencies between tests. If setup changes, every test in the describe block may break. Each test should set up only what it needs — shared setup should be minimal (database connection, auth) and test-specific data should be created in the test itself or a focused helper. (Test Maintainability, Threshold calibrated against Logflare/Mydia)
- **Check:** Measure AST size of `setup` and `setup_all` blocks. Flag above 400 nodes.
- **Tolerate:** Integration test setups with complex multi-system initialization.
- **Severity:** `info`

#### 7.12 Long Test

Test bodies with >1200 AST nodes likely test too many things at once.

- **Why:** A test that sets up data, performs multiple operations, and makes many assertions is testing a scenario, not a behaviour. When it fails, it's hard to identify which part broke. Split into focused tests — each tests one behaviour with one clear assertion. (Test Focus, Threshold calibrated against Logflare/Mydia)
- **Check:** Measure AST size of test bodies. Flag above 1200 nodes.
- **Tolerate:** Integration tests, end-to-end scenario tests.
- **Severity:** `info`

#### 7.13 Mocks Not Verified

Mox setups must call `setup :verify_on_exit!` to enforce that expectations were met.

- **Why:** Without `verify_on_exit!`, Mox doesn't enforce that the expectations actually fired. A test that says `expect(MockClient, :fetch, fn _ -> :ok end)` and never reaches the call still passes — you've documented an interaction the code never made and the test gives false confidence. (Test Validity)
- **Check:** Flag test files that use `Mox.expect` or `Mox.stub` without `verify_on_exit!` in setup.
- **Tolerate:** None — always verify expectations.
- **Severity:** `warning`

#### 7.14 Coverage Gap

Public API functions not referenced in the corresponding test file.

- **Why:** Public functions are the contract a module exposes — every one should have at least one test reference so regressions are caught. Low coverage on public API surfaces means changes can ship without anything noticing they broke a consumer's expected behaviour. (Test Coverage)
- **Check:** Project-level: for each source file, check if its public functions are called or referenced in the corresponding test file. Report coverage percentage and list uncovered functions.
- **Tolerate:** Framework callbacks (init, handle_call, handle_info), `@moduledoc false` modules, `application.ex`.
- **Severity:** `info`

#### 7.15 Mocking Own Modules

Mock at system boundaries only — don't mock modules you own.

- **Why:** Mocks at system boundaries (HTTP, email, external APIs) shield tests from slow/flaky network. Mocking your own internal modules instead of using the real implementation tests the test, not the code: a refactor that breaks behaviour will leave the test green because the test is checking against a stub of the old behaviour. (Test Realism)
- **Check:** Flag `Mox.defmock` targets that appear to be internal modules (same app namespace, not in adapter/client/infrastructure/gateway/boundary path).
- **Tolerate:** Modules explicitly designed as boundary abstractions (adapters, clients, gateways).
- **Severity:** `info`

#### 7.16 Runtime Config for DI

`Application.get_env` at runtime for dependency injection. Use `Application.compile_env` with module attributes.

- **Why:** Pulling the implementation from Application env on every call is slow (an Application lookup per call), not compile-time safe (a typo silently uses the default), and not friendly to Mox: tests have to set the env globally and remember to reset it. `Application.compile_env/3` reads the value once at compile time and pins it into a module attribute — faster, safer, and Dialyzer-visible. (Performance, Safety)
- **Check:** Flag `Application.get_env(:app, :key).function()` dispatch pattern — runtime DI via chained call.
- **Tolerate:** Config files, Application modules, values that genuinely vary at runtime.
- **Severity:** `info`

#### 7.17 Generic Test Names

Test names should be descriptive — not "it works", "test 1", "happy path".

- **Why:** When a test fails, the name is the first (and sometimes only) thing you see in CI output. "it works" tells you nothing. "creates user with valid email and sends welcome notification" tells you exactly what broke and what the expected behaviour is. Good names serve as living documentation of the module's behaviour. (Test Readability, Documentation)
- **Check:** Flag test names matching generic patterns: "it works", "test N", "happy path", "should work", "basic test", "sanity check".
- **Tolerate:** None — rename to describe the specific behaviour being tested.
- **Severity:** `info`

#### 7.18 Weak Assertion

`assert function()` without pattern match — only checks truthiness, not return shape.

- **Why:** `assert Accounts.create_user(attrs)` passes when the function returns `{:error, changeset}` because the tuple is truthy (not nil or false). The test says "creation succeeded" but it didn't — the assertion checked truthiness, not success. `assert {:ok, user} = Accounts.create_user(attrs)` catches the error shape immediately AND binds the result for further assertions. (Assertion Strength, False Positives)
- **Check:** Flag `assert function_call()` where the argument is a function call (remote or local) not wrapped in a pattern match (`=`), comparison (`==`, `!=`), or predicate.
- **Tolerate:** Predicate function calls (`assert Enum.any?(...)`, `assert Map.has_key?(...)`) — already return boolean by convention.
- **Severity:** `info`

#### 7.19 Missing Test Cleanup

Test starts processes directly without `start_supervised!/1` or `on_exit/1` — causes test pollution.

- **Why:** Processes started with `GenServer.start_link` or `Task.start` in tests outlive the test case if not cleaned up. They may interfere with subsequent tests (holding database connections, occupying registered names, consuming port resources), cause test pollution, and make failures non-deterministic. `start_supervised!/1` auto-stops the process when the test ends. `on_exit/1` runs cleanup regardless of test pass/fail. (Test Isolation)
- **Check:** Flag test files that call `GenServer.start_link`, `GenServer.start`, or `Task.start` without `start_supervised!` or `on_exit` cleanup.
- **Tolerate:** Tests using `start_supervised!`, tests with explicit `on_exit` cleanup.
- **Severity:** `info`

#### 7.20 Hardcoded Test Data

Test files containing real-looking email addresses (gmail.com, yahoo.com), Stripe API keys (sk_test_..., pk_test_...), or Bearer tokens.

- **Why:** Hardcoded real email addresses risk accidental side effects in integration tests (sending real emails). Hardcoded API keys risk leaking secrets to version control. Hardcoded production URLs risk hitting real APIs from CI. Use `@example.com` (RFC 2606 reserved), factories with generated values, or environment-based test credentials. (Safety, Test Hygiene)
- **Check:** Scan test file content for regex patterns matching real email providers, API key formats, and Bearer token patterns.
- **Tolerate:** `@example.com` addresses (RFC 2606), `localhost` URLs, obviously fake data.
- **Severity:** `info`

#### 7.21 Test-Only Public Function *(compiled)*

Public function only called from test modules — never from production code.

- **Why:** A public function exercised only by tests suggests the test is reaching into implementation details rather than testing through the public API. Consider making the function `defp` and testing the behaviour through the module's public interface. (Test Architecture, Encapsulation)
- **Check:** Build compiled call graph. Find exported functions where all callers are test modules (modules ending in `Test`, `DataCase`, `ConnCase`, etc.). Exclude framework functions.
- **Tolerate:** Test helper functions intentionally public, functions called dynamically.
- **Severity:** `info`

---

## 8. Event Sourcing Architecture

#### 8.1 Command/Event Naming

Commands use imperative form (CreateAccount), events use past tense (AccountCreated).

- **Why:** Event sourcing relies on the naming convention to distinguish intent from fact: commands express an instruction to do something (imperative), events record that something happened (past tense). A past-tense command name reads like an event and obscures whether the module describes a request or a historical fact. This confusion cascades into handlers, projectors, and process managers. (Domain Language, CQRS Convention)
- **Check:** Flag command modules (under Commands namespace) ending in past-tense suffixes (-ed, -ied, -ten, -ade, etc.), and event modules (under Events namespace) starting with imperative prefixes (Create, Update, Delete, Send, etc.).
- **Tolerate:** Non-event-sourced modules, modules outside Commands/Events namespaces.
- **Severity:** `warning`

#### 8.2 Pure Aggregate Apply

`apply/2` in aggregate modules must be pure — no side effects.

- **Why:** `apply/2` is invoked on every event during aggregate rehydration (process restart), not just when the event is first emitted. Side effects there fire N times per process restart: Logger calls spam observability tooling, HTTP calls re-trigger external systems, and email calls re-send notifications — all silently, on every aggregate load. The function must be a pure transformation: (state, event) → new state. (Event Sourcing Fundamentals, Replay Safety)
- **Check:** Flag calls to Logger, IO, GenServer, HTTP clients, external services, or `send/2` inside `apply/2` functions in modules that have both `execute/2` and `apply/2` (aggregate shape).
- **Tolerate:** Pure state transformations, calculations, struct updates.
- **Severity:** `error`

#### 8.3 Immutable Events

Events must be immutable structs with `defstruct` and `@derive Jason.Encoder`.

- **Why:** Events are persisted facts that get serialized, replayed, and pattern-matched against. A plain module without a struct cannot be deserialized into a known shape, defeats compile-time field checks, and breaks every projector and process manager that pattern-matches the event. Mutating a stored event (`%{event | field: new_value}`) corrupts the audit trail. (Event Integrity, Serialization)
- **Check:** Flag event modules (under Events namespace) without `defstruct`, `defevent`, `typedstruct`, or `embedded_schema`. Also flag struct update syntax on events.
- **Tolerate:** Event macro usage (defstruct generated internally), upcaster modules (explicitly transform events on read).
- **Severity:** `error` / `warning`

#### 8.4 Shared Projections

Projectors must not share read models — rebuilding one corrupts the other.

- **Why:** Each projector owns its read model so it can be rebuilt independently from the event stream. When two projectors write to the same schema/table, rebuilding one wipes or duplicates rows the other still needs, and the order in which they replay starts to matter. The coupling is invisible until you try to rebuild. (Projection Independence)
- **Check:** Graph-based: detect multiple projector modules referencing the same Ecto schema through edges in the module dependency graph.
- **Tolerate:** Reference data tables (countries, currencies) that are populated outside the event stream.
- **Severity:** `warning`

#### 8.5 Events Need Jason.Encoder

Event structs must `@derive Jason.Encoder` for event store serialization.

- **Why:** Event stores serialize events to JSON before persisting. A struct without an encoder either raises at write time (`Protocol.UndefinedError`) or — worse — is silently encoded by a fallback that drops fields, producing events that cannot be replayed into the original shape. (Serialization, Data Integrity)
- **Check:** Flag event modules with `defstruct` but without `@derive Jason.Encoder`.
- **Tolerate:** Events using custom serialization, events with `@derive {Jason.Encoder, only: [...]}`.
- **Severity:** `warning`

#### 8.6 Projector Reads External

Projectors must not call HTTP/external services or non-deterministic functions during projection.

- **Why:** Projectors are replayed against the event log to rebuild read models. An HTTP call talks to a remote service whose response can change, time out, or simply return different data than it did the first time. Non-deterministic calls (`DateTime.utc_now`, `:rand.uniform`) return different values on each replay. The rebuilt projection no longer matches the original — and the discrepancy is invisible until somebody compares. (Replay Determinism)
- **Check:** Flag calls to HTTP clients (HTTPoison, Finch, Req, Tesla), `DateTime.utc_now`, `:rand`, `System.system_time` inside `project/3` callbacks in modules using `Commanded.Projections.Ecto`.
- **Tolerate:** `Repo.get` (reading own projection table — common load-then-update pattern), event metadata timestamps.
- **Severity:** `warning`

#### 8.7 Process Manager Reads Projection

Process manager state must come from events, not from Repo reads on projections.

- **Why:** Process managers must derive their state from the events they have observed, via `apply/2`. Reading from a projection (via `Repo.get`, `Repo.all`) means decisions depend on a read model that may not yet have caught up — leading to race conditions during replay and after restarts, plus invisible coupling to the projector's lifecycle. (Event Sourcing Consistency)
- **Check:** Flag `Repo.get`, `Repo.get!`, `Repo.get_by`, `Repo.one`, `Repo.all` calls inside process manager modules (using `Commanded.ProcessManagers.ProcessManager`).
- **Tolerate:** None in event-handling callbacks.
- **Severity:** `warning`

#### 8.8 Aggregate Missing Behaviour

Modules with `execute/2` and `apply/2` but no `use Commanded.Aggregates.Aggregate`.

- **Why:** A module that walks like an aggregate (command handler + event applier) but doesn't declare itself as one is invisible to the framework: no GenServer wrapper, no snapshotting, no router registration, and the compiler can't check the callback shapes against the behaviour. It may work coincidentally but break when the framework evolves. (Framework Integration)
- **Check:** Flag modules that define both `execute/2` and `apply/2` as public functions without `use Commanded.Aggregates.Aggregate`.
- **Tolerate:** Non-Commanded projects, policy/service modules that happen to use these function names for unrelated purposes.
- **Severity:** `info`

---

## 9. State Machine Architecture

#### 9.1 State Reachability

All defined states must be reachable from initial states via transitions.

- **Why:** An unreachable state is dead code — it was defined but no transition path leads to it. It confuses readers, may indicate a missing transition (a bug), and adds maintenance cost for code that can never execute. (Completeness, Dead Code)
- **Check:** Build a directed graph from transition definitions. BFS/DFS from all initial states. Flag states with no path from any initial state.
- **Tolerate:** States explicitly documented as "reserved for future use."
- **Severity:** `warning`

#### 9.2 Terminal State Integrity

States named like terminal states (completed, cancelled, failed) should have no outgoing transitions except self-loops.

- **Why:** States named `completed`, `cancelled`, `failed`, `terminated`, `done`, `closed`, `archived`, `deleted`, `expired` are conventionally terminal — once entered, they shouldn't transition out. A terminal state with outgoing edges either means the state isn't really terminal (misleading name) or the transitions are bugs that let entities resurrect from a final state. Either way, the state diagram is inconsistent with itself. (State Machine Consistency)
- **Check:** Flag states with terminal-sounding names that have transitions to non-self states.
- **Tolerate:** Self-loops (e.g., `completed → completed` for idempotent retries).
- **Severity:** `warning`

#### 9.3 Implicit Boolean State

Schemas with 3+ state-suggesting boolean fields (is_active, is_verified, is_suspended) — use a single status enum.

- **Why:** When an entity has 3+ booleans like `is_active`, `is_verified`, `is_suspended`, the schema implicitly defines a 2^n state machine where most combinations are invalid (e.g., `active=true, suspended=true`). The valid states aren't documented, the invalid ones can be created by mistake, and reasoning about transitions becomes detective work. A single `:status` enum field makes states explicit and invalid combinations unrepresentable. (State Representation, Data Integrity)
- **Check:** Count boolean fields with state-suggesting names (`is_*`, `has_*`, `was_*`, `*_active`, `*_enabled`, `*_verified`, `*_completed`, `*_confirmed`, etc.) in Ecto schema modules. Flag schemas with 3+ such fields.
- **Tolerate:** Independently meaningful booleans (`can_email`, `can_sms`, `can_push` — capabilities, not states) where every combination is valid.
- **Severity:** `info`

---

## 10. Composition and Extensibility

#### 10.1 Shallow Use

Prefer composition over deep `use` chains. More than 2 non-standard `use` statements per module.

- **Why:** Deep `use` chains are the functional equivalent of multiple inheritance. Each `use` injects functions, attributes, and `__using__` macros into the module's scope, but the reader can't see what was added without reading every `__using__` body. The implicit coupling makes refactors fragile and overrides surprising — you don't know what you're overriding because you don't know what was injected. (Explicitness, Readability)
- **Check:** Count non-standard `use` statements per module (excluding GenServer, Agent, Supervisor, DynamicSupervisor, Task, ExUnit.Case, ExUnit.CaseTemplate, Phoenix.Controller, Phoenix.LiveView, Phoenix.LiveComponent, Phoenix.Component, Phoenix.Channel, Ecto.Schema, Ecto.Migration, Plug.Builder, Plug.Router, Application). Flag above 2.
- **Tolerate:** Test files (often use multiple test case templates).
- **Severity:** `info`

#### 10.2 Namespace Depth

Module nesting should not exceed the configured maximum depth.

- **Why:** `MyApp.Foo.Bar.Baz.Qux.Internal.Helper` is 7 levels deep — each level adds organizational overhead without adding clarity. Deep nesting usually indicates over-decomposition or a directory structure mimicking Java packages. Elixir's flat module namespace works best with 3-4 levels: `MyApp.Context.SubModule`. (Readability, Convention)
- **Check:** Count dots in the module name. Flag above the configured threshold.
- **Tolerate:** Generated modules, umbrella app prefixes (which add one level).
- **Severity:** `info`

---

## 11. Native Interop (NIFs, Ports, Rustler)

#### 11.1 NIF Behind Behaviour

NIF modules should implement a behaviour for replaceability and testing.

- **Why:** NIFs are native code that lives outside the BEAM's safety net: a crash takes the whole VM down. Hiding the NIF behind a behaviour gives you a clean abstraction: tests can swap in a pure Elixir implementation, the public surface is documented via `@callback`, and consumers depend on the behaviour rather than the unsafe native module directly. (Testability, Safety, Abstraction)
- **Check:** Flag modules with `use Rustler`, `use Zig`, `@on_load`, or `:erlang.nif_error` that don't declare or implement a `@behaviour`.
- **Tolerate:** None — all NIFs should have a behaviour boundary.
- **Severity:** `warning`

#### 11.2 NIF Scheduler Safety

NIFs processing variable-size input should use dirty schedulers to avoid blocking the BEAM.

- **Why:** Regular NIFs run on the BEAM's normal schedulers. Anything that takes more than ~1ms blocks the scheduler and prevents thousands of other processes from making progress. Operations on user-supplied binaries or lists can vary wildly in size, and a slow run starves the entire VM. Dirty schedulers give the BEAM dedicated threads for these operations. (BEAM Safety, Latency)
- **Check:** Flag NIF modules with stub functions (`raise "NIF not loaded"` or `:erlang.nif_error`) but no dirty scheduler configuration (`DirtyCpu`, `DirtyIo`, `dirty: :cpu`).
- **Tolerate:** NIFs proven to complete in <1ms, fixed-size operations.
- **Severity:** `warning`

#### 11.3 NIF Panic Patterns

Rust NIF code must not contain `unwrap()`, `expect()`, `panic!()`, or `todo!()` — these crash the entire VM.

- **Why:** NIF Rust code runs in the same OS process as the BEAM. Any Rust panic propagates as a process abort, killing the entire VM along with every process, connection, and in-flight request it serves. The same code in non-NIF Rust would just unwind the thread; in a NIF it's a global outage. Replace with `?` operator and Result-returning functions that convert errors to Elixir `{:error, reason}` tuples. (VM Safety, Availability)
- **Check:** Scan `.rs` files in `native/` directories for `unwrap()`, `.expect(`, `panic!(`, `todo!(`, `unimplemented!(`. Skip `#[cfg(test)]` blocks (test code is fine) and comment lines.
- **Tolerate:** Test modules, static initialization that cannot fail.
- **Severity:** `warning`

#### 11.4 Port vs NIF Decision

Choose Port when safety matters more than NIF latency. Ports run in a separate OS process.

- **Why:** Ports run in a separate OS process — crashes don't take down the BEAM and there's no scheduler concern at all. They cost more per call than NIFs (inter-process communication overhead) but eliminate the safety class entirely: a bug in a Port crashes the Port, not the VM. NIFs should only be used when the latency difference (microseconds vs milliseconds) is critical for the use case. (Safety vs Performance Tradeoff)
- **Check:** Flag NIF modules that primarily do I/O (file, network, database) rather than tight computation — Ports would be safer for I/O-bound work.
- **Tolerate:** Computation-heavy NIFs (crypto, image processing, parsing), latency-critical hot paths.
- **Severity:** `info`

---

## Rule Summary

| Category | Count | Rule IDs |
|----------|-------|----------|
| Boundaries | 30 | 1.1–1.23, 2.1–2.3, 4.5–4.8, 4.11, 4.17 |
| Single Source of Truth | 6 | 3.1–3.6 |
| Coupling & Abstraction | 26 | 4.1–4.4, 4.9–4.10, 4.12–4.16, 4.18–4.26 |
| OTP Process Architecture | 40 | 5.1–5.42 |
| Module Quality | 31 | 6.1–6.32 |
| Test Architecture | 19 | 7.1–7.21 |
| Event Sourcing | 8 | 8.1–8.8 |
| State Machine | 3 | 9.1–9.3 |
| Composition | 2 | 10.1–10.2 |
| Native Interop | 4 | 11.1–11.4 |
| **Total** | **166** | |

Rules marked *(compiled)* require the `--compiled` flag and work by analyzing beam files after `mix compile`. They see ground-truth dependencies after macro expansion — no AST guessing.

## Severity Levels

| Severity | Meaning | CLI exit code |
|----------|---------|---------------|
| `:error` | Almost always a bug. | 2 |
| `:warning` | Almost always wrong, may have legitimate exceptions. | 1 |
| `:info` | Architectural smell, often a judgment call. | 0 |

## What These Rules Do NOT Enforce

- **Specific project structure** — flat, umbrella, and poncho are all valid
- **Specific architecture style** — Phoenix contexts, event sourcing, Ash domains all pass
- **Code formatting** — that's `mix format`
- **Naming style** — that's Credo
- **Type correctness** — that's Dialyzer
- **Security vulnerabilities** — that's Sobelow
- **Performance** — that's benchmarking and profiling

These rules fill the gap: **structural quality, boundary integrity, error handling idioms, and test architecture** — the things that only become visible when you look at how modules connect, how processes interact, and how the codebase evolves over time.
