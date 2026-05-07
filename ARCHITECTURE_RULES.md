# Archdo — Architectural Quality Rules for Elixir

> 329 rules that complement Credo (style), Dialyzer (types), and Sobelow (security) by checking **system architecture**, **OTP discipline**, **error handling idioms**, **test quality**, and **compiled beam analysis** — the gap none of them cover.

<!--
  ENTRY TEMPLATE — every rule MUST follow this shape so the reference
  document stays scannable. Exceptions for genuinely complex rules are
  fine; they should be the minority.

      ### N.M Title

      One-line summary describing what the rule detects.

      - **Why:** Architectural rationale (1–3 sentences). Concept tags
        in parens at the end: (SOLID-D, Hexagonal, Performance, etc.)
      - **Check:** What the analyzer actually does (AST shape, graph
        query, registry lookup). One short paragraph.
      - **Tolerate:** Exceptions / suppression markers / common
        legitimate patterns the rule must not flag.
      - **Severity:** `error` / `warning` / `info`

  Optional extras (use sparingly, only when they add clarity):
    - ASCII diagram (1.1 has the canonical example)
    - BAD/GOOD code blocks for non-obvious patterns
    - Sub-check enumeration when one rule covers multiple shapes (6.50)

  Coverage check: `mix archdo.audit_doc_coverage` — fails CI when a new
  rule lands without an entry here. Baselines:
    - priv/doc_coverage_baseline.txt        (acknowledged-missing rules)
    - priv/doc_coverage_stale_baseline.txt  (acknowledged-stale entries)
-->

## Contents

1. [Boundary Integrity](#1-boundary-integrity) — 33 rules (1.1–1.36, 1.1b)
2. [Public API Quality](#2-public-api-quality) — 3 rules (2.1–2.3)
3. [Single Source of Truth](#3-single-source-of-truth) — 6 rules (3.1–3.6)
4. [Coupling & Abstraction](#4-coupling--abstraction) — 29 rules
5. [OTP Process Architecture](#5-otp-process-architecture) — 71 rules (5.1–5.76)
6. [Module Quality](#6-module-quality) — 99 rules (6.1–6.103)
7. [Test Architecture](#7-test-architecture) — 31 rules (7.1–7.35)
8. [Event Sourcing](#8-event-sourcing-architecture) — 9 rules (8.1–8.9)
9. [State Machine](#9-state-machine-architecture) — 6 rules (9.1–9.3, SM-A/D/F)
10. [Composition](#10-composition-and-extensibility) — 6 rules (10.1–10.6)
11. [Native Interop](#11-native-interop-nifs-ports-rustler) — 4 rules (11.1–11.4)
12. [Change Economy](#12-change-economy) — 32 rules (CE-1 … CE-57)

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

### 1.23 Context Boundary Quality *(compiled)*

Measures cohesion, coupling, and encapsulation of automatically discovered contexts.

- **Why:** High-quality boundaries have high internal cohesion (modules within the context call each other), low external coupling (few cross-boundary calls), and clear encapsulation (calls go through boundary modules, not internals). Compiled data provides ground-truth call counts. (Bounded Context, Modularity)
- **Check:** Discover contexts from namespace clustering, compute cohesion ratio (internal calls / total calls), coupling ratio (cross-boundary calls / total), and leak ratio (calls bypassing the boundary module).
- **Tolerate:** Small contexts with fewer than 3 modules. Shared infrastructure contexts.
- **Severity:** `info`

### 1.24 Circular Context Dependencies *(compiled)*

Context A depends on Context B which depends on Context A.

- **Why:** Circular dependencies between bounded contexts prevent independent deployment, testing, and reasoning. They indicate the contexts are not properly separated — either the boundary is wrong or shared logic needs extraction. (Acyclic Dependencies Principle)
- **Check:** Build context-level adjacency map from compiled call graph, detect cycles via DFS.
- **Tolerate:** Circular dependencies through shared infrastructure (e.g., both contexts using Repo).
- **Severity:** `warning`

### 1.25 Orphan Module *(compiled)*

Module has zero incoming AND zero outgoing dependencies within the project.

- **Why:** A completely disconnected module is either dead code, a missing integration, or a standalone utility that should be in a separate package. (Dead Code, Cohesion)
- **Check:** Check `module_dependencies` and `module_dependents` from compiled graph — both empty.
- **Tolerate:** Behaviour definitions (they're implemented, not called). Application entry points. Test support modules.
- **Severity:** `info`

### 1.26 Reverse Dependency — Domain References Web Layer

Domain module imports, aliases, or calls a web-layer module.

- **Why:** Domain modules must be framework-agnostic. When domain code depends on controllers, LiveView, or router helpers, it can't be reused outside the web context, tested without the framework, or extracted into a library. (Dependency Inversion)
- **Check:** Walk AST for aliases/imports/calls containing `Web` in the module path. Skip web-layer files (`*_web.ex`, `*_web/`).
- **Tolerate:** None — this is always wrong.
- **Severity:** `warning`

### 1.27 Business Logic in LiveView handle_event

LiveView `handle_event` callback contains business logic instead of delegation.

- **Why:** `handle_event` should translate user input, delegate to a context module, and assign the result to the socket. Business logic in handle_event can't be tested without mounting a LiveView, is duplicated across similar LiveViews, and couples the UI to the domain. (Thin Controller)
- **Check:** Count AST nodes in `handle_event` bodies excluding assign calls. Flag when > 10 non-assign nodes.
- **Tolerate:** Simple form handling where the logic IS the assignment. LiveViews that are the context (no backend).
- **Severity:** `info`

### 1.28 Ecto.Query in Interface Layer

Controllers, LiveViews, or channels build Ecto queries directly.

- **Why:** Query building in the interface layer bypasses context boundaries. Queries get duplicated across controllers, the context can't enforce business rules, and schema changes require updating the web layer. (Boundary Encapsulation)
- **Check:** Find `import Ecto.Query`, `from(...)`, or `Ecto.Query.*` calls in controller/LiveView/channel files.
- **Tolerate:** None — queries always belong in context modules.
- **Severity:** `warning`

### 1.29 Cross-Context Schema Access

Module constructs or pattern-matches a struct from another context.

- **Why:** Directly using `%OtherContext.Schema{}` creates invisible coupling. If the schema changes fields, every cross-context usage breaks. Access data through the owning context's public API instead. (Data Encapsulation)
- **Check:** Find `{:%, _, [{:__aliases__, _, aliases}, ...]}` where the context prefix differs from the current file's context.
- **Tolerate:** Shared data-carrier structs explicitly designed for cross-boundary use. Test fixtures.
- **Severity:** `info`

### 1.30 Direct GenServer.call Across Context Boundary

Module calls `GenServer.call/cast` to another context's process by name.

- **Why:** Calling another context's GenServer directly bypasses its public API. The caller becomes coupled to the process name, message format, and internal state shape. (Process Encapsulation)
- **Check:** Find `GenServer.call/cast` with a module-path target from a different context.
- **Tolerate:** Infrastructure processes (PubSub, Registry) that are shared by design.
- **Severity:** `info`

### 1.31 Shared Database Table Across Contexts

Multiple contexts define Ecto schemas for the same database table.

- **Why:** When two contexts both define schemas for the same table, neither truly owns the data. Changes to the table structure require coordinating across context boundaries — invisible coupling through the database. (Data Ownership)
- **Check:** Project-level: collect `schema "table_name"` calls, group by table, flag tables with schemas in multiple contexts.
- **Tolerate:** Read-only view schemas. Intentionally shared reference data tables.
- **Severity:** `warning`

### 1.32 Cross-Context Application Config Read

Module reads Application config for another context's module.

- **Why:** Reading another context's configuration creates hidden coupling. Each context should own its own configuration and expose what others need through its public API. (Configuration Encapsulation)
- **Check:** Find `Application.get_env/fetch_env/compile_env` with a module path from a different context.
- **Tolerate:** Shared infrastructure config (Repo URL, endpoint config).
- **Severity:** `info`

### 1.33 Shared ETS Table Across Contexts

Multiple contexts access the same named ETS table directly.

- **Why:** Named ETS tables shared between contexts create coupling through shared mutable state. Changes to the table structure, key format, or access patterns in one context silently break the other. (State Encapsulation)
- **Check:** Project-level: collect `:ets.lookup/insert/delete` calls with atom table names, group by context, flag tables accessed from multiple contexts.
- **Tolerate:** Dedicated shared cache modules with a typed public API. Registry tables.
- **Severity:** `info`

### 1.34 MVC-Style Directory Layout (`models/`, `services/`, `helpers/`)

A file lives under `lib/<app>/models/`, `lib/<app>/services/`, or non-web `lib/<app>/helpers/` — directories named for technical role rather than domain.

- **Why:** Elixir code is organized by bounded context, not by layer. `models/` is an MVC convention that pushes behavior away from data and produces anemic schemas; `services/` is a Java/Spring naming that doubles up the namespace and tells you nothing about the domain; non-web `helpers/` is a junk drawer. The context module IS the service: `MyApp.Billing` is both the public API and the place where Billing's logic and schemas co-locate. (Domain-Driven, Screaming Architecture)
- **Check:** Path classifier. Splits `Path.split(file)`, looks under `lib/<app>/`, and flags any segment matching `models`, `services`, or `helpers`. The `lib/<app>_web/helpers/` Phoenix scaffolding is exempt — that's the framework's own convention.
- **Tolerate:** Phoenix-generated `lib/my_app_web/helpers/`. Test files (skipped via `AST.test_file?`). Truly value-type modules whose name describes what they do (`MyApp.Money`, `MyApp.Slug`) — those should sit at the context root, not under `helpers/`.
- **Severity:** `warning`

### 1.35 Bang Function Without Non-Bang Sibling

A public `name!/n` exists without a matching `name/n` returning `{:ok, _} | {:error, _}`.

- **Why:** Pairing the two lets callers choose: callers that have already validated input use the bang for terse code (seeds, scripts, fixtures); callers handling expected failure use the non-bang and pattern-match. A lone bang forces all callers to `try`/`rescue` (anti-pattern) or duplicate the success/failure logic. The stdlib follows this rigorously: `File.read/1` + `File.read!/1`, `Map.fetch/2` + `Map.fetch!/2`. (Convention)
- **Check:** Per-module: collect every `def name!/n` and verify the same module also defines `def name/n`. Internal `defp` bangs are exempt; the rule is about the public surface.
- **Tolerate:** Functions whose only failure mode is a programmer error (then drop the bang and rename — there's no useful non-bang to pair with). Bang variants where the error path genuinely cannot happen at runtime.
- **Severity:** `info`

### 1.36 Circuit Breaker in Context Module

A context module calls `:fuse.ask`, `ExBreaker.execute`, or a similar circuit-breaker primitive directly.

- **Why:** Hexagonal / ports-and-adapters places the breaker INSIDE the adapter that wraps the external service, not in the domain. The context calls the adapter behaviour and pattern-matches on its `{:ok, _}` / `{:error, :unavailable}` return — completely unaware that a breaker exists. This lets you swap or remove the breaker without touching domain code, keeps the adapter mock breaker-free, and keeps the domain focused on business rules. (Hexagonal, Single Responsibility)
- **Check:** AST scan: find calls to known breaker libraries (`:fuse.ask/melt/install`, `ExBreaker.execute`, `Fuse.melt`) inside files classified as context modules (not under `*_adapter.ex`, `*/adapters/`, `*/clients/`).
- **Tolerate:** Breaker calls in adapter modules (`MyApp.Billing.StripeAdapter`, `lib/my_app/adapters/`). Breaker installation in `Application.start/2` (one-time wiring).
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

### 4.27 Unused Alias

Alias is declared but the short name is never referenced.

- **Why:** An unused alias adds noise to the module header and suggests a dependency that doesn't exist. It may be a leftover from a refactoring that removed the code using it. (Minimal Dependencies, Clarity)
- **Check:** Extract all simple alias declarations, count references to each short name in `{:__aliases__, _, [first | _]}` nodes. Flag when zero references.
- **Tolerate:** `alias Foo.{Bar, Baz}` multi-alias syntax (harder to track). `alias Foo, as: Bar` where `Bar` is used.
- **Severity:** `info`

### 4.28 N+1 Preload in Loop

`Repo.preload/get/one/all` inside Enum callbacks or `for` comprehensions.

- **Why:** Calling Repo inside a loop executes one query per iteration — the classic N+1 problem. For 100 items, this is 101 queries instead of 2. Use `Repo.preload(list, :assoc)` to batch. (Performance, Database)
- **Check:** Find `Repo.preload/get/one/all` calls inside all loop constructs: Enum, Stream, `:lists`, `for`, `receive`, `Task.async_stream`, and recursive function bodies.
- **Tolerate:** `Repo.preload` outside loops. Streams that batch internally.
- **Severity:** `warning`

### 4.29 Dev Dependency Without `only:` Option

Well-known dev/test package missing `only: [:dev, :test]` — will be included in production releases.

- **Why:** Dependencies without `only: :dev` are compiled into production releases. Dev tools like Credo, Dialyxir, and ExDoc add unnecessary code, increase release size, and may expose dev-only functionality. (Release Hygiene)
- **Check:** Scan `mix.exs` deps for known dev-only packages (credo, dialyxir, ex_doc, mox, etc.) without `only:` option.
- **Tolerate:** `:esbuild` and `:tailwind` (Phoenix 1.8+ deliberately omits `only:` for asset build).
- **Severity:** `warning`

### 4.30 Umbrella Dependency Inconsistency

Umbrella child dep with `in_umbrella: true, runtime: false` but no `only:` restriction.

- **Why:** `runtime: false` without `only:` means the dependency is compiled in all environments but never started. This may be intentional (compile-time types/macros) or a misconfiguration. (Dependency Hygiene)
- **Check:** Find deps with both `in_umbrella: true` and `runtime: false` but no `only:` option.
- **Tolerate:** Compile-time-only dependencies (type definitions, macros).
- **Severity:** `info`

---

## 5. OTP Process Architecture

### 5A. Process Lifecycle

### 5.1 All Long-Running Processes Must Be Supervised

No bare `spawn`, `spawn_link`, or unlinked `GenServer.start` for processes that should persist.

- **Why:** Unsupervised processes die silently. No restart, no logging, no visibility in Observer or LiveDashboard. The supervision tree IS the architecture — processes outside it are invisible. (OTP Fundamentals, Error Kernel)
- **Check:** Flag `spawn/1,3`, `spawn_link/1,3`, `GenServer.start/2,3` (the non-link variant), `Agent.start/1,2`, `Task.start/1`, `Task.start_link/1` in non-test code.
- **Tolerate:** Test helpers, `Task.async`/`Task.await` pairs within a single function scope, `spawn_monitor` with explicit `:DOWN` handler.
- **Severity:** `warning`

### 5.2 No Unnecessary Processes

Modules that wrap pure functions in a GenServer without needing state, concurrency, or fault isolation.

- **Why:** Official Elixir docs: "A GenServer must never be used for code organization purposes." Valid reasons to spawn a process: (1) mutable state, (2) concurrent execution, (3) failure isolation, (4) resource management. If none apply, use a module with functions. Each process costs ~327 words of heap, adds message-copy overhead, and serializes all access. (Official Anti-Patterns, Saša Jurić)
- **Check:** Flag GenServer modules with trivial init state (`%{}`, `[]`, `nil`) and no state mutations across callbacks.
- **Tolerate:** Rate limiters, connection pools, registered processes, framework-required processes (Membrane Bin/Source/Sink/Filter, Broadway, GenStage, Phoenix Channel).
- **Severity:** `info`

### 5.3 Agent Misuse

Agent used as read-heavy cache where ETS with `read_concurrency: true` would be faster and non-blocking.

- **Why:** Agent serializes ALL access — reads block behind writes. For read-heavy workloads, ETS with `read_concurrency: true` is orders of magnitude faster. Agent also blocks the caller while executing the anonymous function inside the Agent process. (Process Bottleneck)
- **Check:** Flag Agent modules where state is a Map and module name suggests caching (`*Cache*`, `*Store*`, `*Registry*`).
- **Tolerate:** Small-scale Agent in low-concurrency applications, Agent as simple config holder.
- **Severity:** `info`

### 5.4 No Flat Supervision Trees

Supervisor with too many direct children — group related processes under sub-supervisors with appropriate strategies.

- **Why:** A flat tree with 20 children means one strategy for all. Related processes that should restart together (Registry + DynamicSupervisor) are treated as independent. Sub-supervisors with `:rest_for_one` or `:one_for_all` express process dependencies correctly. (Supervision Design)
- **Check:** Count children in `Supervisor.init` or `Supervisor.start_link`. Flag above threshold.
- **Tolerate:** Small applications with genuinely independent processes.
- **Severity:** `info`

### 5.6 Default Supervisor Restart Budget

Supervisors relying on default `max_restarts: 3, max_seconds: 5`.

- **Why:** Defaults are rarely correct for production. A connection pool may need higher tolerance for transient failures; a critical service may need stricter limits to fail fast. Explicit values document the operational intent. (Production Readiness)
- **Check:** Flag `Supervisor.start_link` and `Supervisor.init` without explicit `max_restarts`/`max_seconds` options.
- **Tolerate:** Test supervision trees.
- **Severity:** `info`

### 5.7 Restart Type Mismatch

Restart type must match process lifecycle: `:permanent` for long-running GenServers, `:transient` for tasks.

- **Why:** A `:permanent` task restarts after normal completion — looping forever, hitting max_restarts, and bringing down the supervisor. A `:temporary` GenServer never restarts after crash — the service silently disappears. (OTP Semantics)
- **Check:** Flag Task-like modules with `restart: :permanent`, GenServer modules with `restart: :temporary`.
- **Tolerate:** Intentional one-shot GenServers, intentional persistent task loops.
- **Severity:** `warning`

### 5B. GenServer Hygiene

### 5.8 No Blocking Work in init/1

GenServer `init/1` must not block on I/O, HTTP, or database queries.

- **Why:** `init/1` blocks the caller (usually a supervisor). A slow init delays the entire supervision tree startup, and a crashing init triggers supervisor restart intensity limits that may bring down the whole tree. (Startup Performance, Supervision Safety)
- **Check:** Flag calls to Repo, HTTP clients, File.read, external services inside init/1 function bodies.
- **Tolerate:** Reading config files, ETS table creation, fast local operations.
- **Severity:** `warning`

### 5.9 No Blocking Operations in GenServer Callbacks

`handle_call`, `handle_cast`, `handle_info` must not block on I/O.

- **Why:** A blocked callback makes the GenServer unresponsive. Other callers queue up, their GenServer.call timeouts fire (crashing them), and the process appears hung while actually waiting for a slow external call. Offload to Task. (Responsiveness)
- **Check:** Flag calls to known blocking functions (HTTP clients, `Repo.*`, `File.*`) inside handle_call, handle_cast, handle_info callback bodies.
- **Tolerate:** Quick reads, ETS operations, in-memory computations, `handle_continue` (intentional async).
- **Severity:** `warning`

### 5.11 No receive Inside GenServer Callbacks

`receive` inside a GenServer callback blocks the GenServer from processing its mailbox.

- **Why:** GenServer callbacks should return promptly. A `receive` inside a callback blocks the process from handling other messages — defeating the purpose of a GenServer's ordered mailbox processing. The GenServer is stuck waiting for a specific message while all other messages queue up. (Mailbox Processing)
- **Check:** Flag `receive` blocks inside GenServer callback function bodies.
- **Tolerate:** None — this is always a design error.
- **Severity:** `warning`

### 5.12 Use handle_continue Instead of send(self()) in init

`send(self(), :init_work)` in `init/1` should be `{:ok, state, {:continue, :init_work}}`.

- **Why:** `send(self())` in init puts a message in the mailbox — but other messages (from processes that already know about this GenServer) may arrive first, causing the process to handle requests before initialization completes. `handle_continue` runs before any other message. (Initialization Order)
- **Check:** Flag `send(self(), _)` inside `init/1`.
- **Tolerate:** Pool/cache patterns where interleaving is intentional (NimblePool does this so the pool stays responsive during worker creation).
- **Severity:** `info`

### 5.13 Cast Where Call is Needed

`GenServer.cast` used where `GenServer.call` is more appropriate — operations that need confirmation.

- **Why:** Cast is fire-and-forget — the caller never knows if the operation succeeded, failed, or was even received. For operations involving data mutation, status changes, or resource allocation, call provides backpressure (caller blocks), error propagation (caller gets the error), and ordering guarantees. (Reliability)
- **Check:** Flag `GenServer.cast` for messages whose names suggest confirmation is needed (`:create`, `:update`, `:delete`, `:insert`, `:write`, `:save`, `:store`) or that interact with Repo.
- **Tolerate:** Logging, metrics, notifications, broadcast, fire-and-forget cache invalidation.
- **Severity:** `info`

### 5.14 Silent handle_info Catch-All

`handle_info` catch-all must not swallow messages silently.

- **Why:** A catch-all `def handle_info(_, state), do: {:noreply, state}` silently discards unexpected messages — timer messages from Process.send_after, monitor `:DOWN` signals, TCP socket data, PubSub broadcasts. The process appears healthy while losing data and leaking resources. (Silent Failure)
- **Check:** Flag `handle_info` catch-all clauses whose body doesn't log, re-raise, or return an error.
- **Tolerate:** Explicitly documented catch-alls with a comment explaining the intent.
- **Severity:** `warning`

### 5.15 Timeout as Polling

GenServer `{:noreply, state, timeout}` return used as a polling mechanism.

- **Why:** The GenServer timeout fires only if no message arrives within the interval — ANY message resets the timer, making polling unreliable. Use `Process.send_after(self(), :poll, interval)` or `:timer.send_interval` for reliable periodic work. (Reliability)
- **Check:** Flag `{:noreply, state, integer}` return patterns in callbacks.
- **Tolerate:** Idle timeouts (intentional inactivity detection is the correct use of GenServer timeout).
- **Severity:** `info`

### 5.16 Missing terminate/2

GenServers holding resources (connections, file handles, external sessions) should implement `terminate/2`.

- **Why:** Without `terminate/2` and `Process.flag(:trap_exit, true)`, resources leak on process death. Connections stay open, file handles linger, external sessions aren't cleaned up. The supervisor restarts the process but the old resources are orphaned. (Resource Management)
- **Check:** Flag GenServer modules that acquire resources in init (open connections, start external sessions) but don't implement `terminate/2`.
- **Tolerate:** Stateless GenServers, processes whose resources auto-cleanup on process death.
- **Severity:** `info`

### 5.17 Scattered GenServer.call/cast

GenServer.call/cast should only be used in the defining module's client API, not scattered across the codebase.

- **Why:** The message protocol (atoms and tuples sent via call/cast) is an implementation detail. Other modules should call public API functions (`MyServer.get_status()`) that wrap the GenServer.call internally. This encapsulates the protocol and allows the GenServer to change its message format without updating every caller. (Encapsulation)
- **Check:** Flag `GenServer.call(MyModule, ...)` and `GenServer.cast(MyModule, ...)` from outside `MyModule`.
- **Tolerate:** Test files, supervisor modules.
- **Severity:** `info`

### 5.18 Synchronous Call Chains

No synchronous `GenServer.call` chains from within callbacks — risk of deadlock.

- **Why:** GenServer.call from handle_call creates a synchronous chain. If the target process calls back (directly or through intermediaries), deadlock. Even without circular calls, chained calls multiply latency and create cascading timeouts when one link is slow. (Deadlock Risk, Latency)
- **Check:** Flag `GenServer.call` inside `handle_call`, `handle_cast`, `handle_info` callbacks.
- **Tolerate:** Calls to processes known to be fast and non-circular (ETS-backed caches).
- **Severity:** `warning`

### 5.19 Large Messages

Don't send entire `Plug.Conn` or large structs to other processes.

- **Why:** Messages are copied between process heaps in the BEAM (except large binaries which are reference-counted). Sending a full Conn (with body, headers, assigns, private data) copies megabytes per request. Send only the data the receiving process needs. (Memory, Performance)
- **Check:** Flag `send/2`, `GenServer.call/cast` where the message pattern includes Conn-like patterns or the Conn variable is captured by a spawned function.
- **Tolerate:** Small messages, binary references (not copied).
- **Severity:** `warning`

### 5.37 Missing handle_info

GenServer without any `handle_info/2` clause — unexpected messages pile up in mailbox.

- **Why:** Any message sent to a GenServer that isn't a call or cast arrives via `handle_info/2`. This includes monitor `:DOWN` messages, timer messages from `Process.send_after`, TCP/UDP socket data, and stray messages from linked processes. Without handle_info, these accumulate in the mailbox — the mailbox grows silently until the process is killed by OOM or the scheduler degrades. (Silent Resource Leak)
- **Check:** Flag GenServer modules (not gen_statem which uses handle_event) that define no `handle_info/2` clauses.
- **Tolerate:** gen_statem modules, simple GenServers that genuinely receive no messages (rare — monitors and timers are common).
- **Severity:** `info`

### 5.38 GenServer.call to Self — Deadlock

`GenServer.call(__MODULE__)` or `GenServer.call(self())` from within a callback causes instant deadlock.

- **Why:** A GenServer processes one message at a time. If `handle_call/3` calls `GenServer.call(__MODULE__, ...)`, the call blocks waiting for a reply — but the GenServer can't process the new call because it's still in the current callback. The process hangs forever, the caller times out, and the supervisor eventually kills it. (Deadlock)
- **Check:** Flag `GenServer.call` targeting `__MODULE__` or `self()` inside callback functions (handle_call, handle_cast, handle_info, handle_continue).
- **Tolerate:** None — this is always a bug. Extract the logic into a private function.
- **Severity:** `warning`

### 5.39 Brutal Kill

`Process.exit(pid, :kill)` bypasses `terminate/2` — data may be lost.

- **Why:** `:kill` is an untrappable signal — the target process dies immediately without running `terminate/2`. Any in-flight work, open file handles, pending database writes, or external session cleanup is skipped. Use `{:shutdown, reason}` or `:shutdown` instead, which allow the process to clean up gracefully. Reserve `:kill` for truly stuck processes that don't respond to shutdown. (Graceful Shutdown, Data Safety)
- **Check:** Flag `Process.exit(pid, :kill)` in non-test code.
- **Tolerate:** Test cleanup, emergency kill for stuck processes.
- **Severity:** `warning`

### 5.41 Hardcoded Call Timeout

`GenServer.call` with hardcoded integer timeout instead of a named constant.

- **Why:** Hardcoded timeout values scattered across call sites make it impossible to tune timeouts without finding every occurrence. Different environments (dev with slow startup vs prod with fast paths) and different load conditions may need different values. A module attribute or function parameter makes the value discoverable and adjustable. (Configuration, Maintainability)
- **Check:** Flag `GenServer.call(server, msg, integer_literal)` where the third argument is a hardcoded integer.
- **Tolerate:** Test code, one-off scripts.
- **Severity:** `info`

### 5C. Task Discipline

### 5.20 Monitor Without Handler

`Process.monitor/1` called without corresponding `:DOWN` handler in the same module.

- **Why:** Monitors send `{:DOWN, ref, :process, pid, reason}` messages to the monitoring process. Without a `handle_info({:DOWN, ...})` clause, these messages pile up in the mailbox, consuming memory and never triggering cleanup. The monitor is effectively dead code. (Silent Leak)
- **Check:** Flag `Process.monitor` in modules that don't have a `handle_info` clause matching `{:DOWN, _, :process, _, _}`.
- **Tolerate:** Modules where :DOWN is handled via a catch-all or in a different module.
- **Severity:** `warning`

### 5.21 Spawn Without Link or Monitor

`spawn/1` without link or monitor — failures go unnoticed.

- **Why:** A spawned process that crashes without a link or monitor is invisible. Nobody knows it died, no cleanup happens, and the work is silently lost. The caller continues as if the spawned work is running. (Silent Failure)
- **Check:** Flag bare `spawn/1,3` without corresponding `Process.monitor` or `Process.link` in the same function.
- **Tolerate:** Test helpers, diagnostic/debugging code.
- **Severity:** `warning`

### 5.22 Task.async Without Task.await

`Task.async` creates a linked task that MUST be awaited — the result is otherwise lost.

- **Why:** `Task.async` links the task to the caller and sets up a protocol expecting `Task.await` or `Task.yield`. Not awaiting means: (1) the task result is lost, (2) the linked task may crash the caller unexpectedly, (3) the task ref leaks. Use `Task.Supervisor.start_child` for fire-and-forget. (Task Protocol)
- **Check:** Flag `Task.async` calls in functions that don't call `Task.await`, `Task.yield`, or `Task.yield_many`.
- **Tolerate:** Results handled via `handle_info` in GenServers (the task sends a message on completion).
- **Severity:** `warning`

### 5.23 Unsupervised Task

`Task.start/1` or `Task.start_link/1` in production code instead of `Task.Supervisor`.

- **Why:** Bare `Task.start` creates a process outside any supervisor. If it crashes, nobody knows. `Task.Supervisor.start_child` creates the task under a supervisor with proper error handling, restart strategies, and shutdown behaviour. (Supervision)
- **Check:** Flag `Task.start/1` and `Task.start_link/1` in non-test code.
- **Tolerate:** Test code, scripts, interactive sessions.
- **Severity:** `info`

### 5D. ETS Patterns

### 5.27 ETS as Message Bus

ETS used as a communication channel between processes instead of message passing.

- **Why:** ETS polling is inefficient (busy-wait or timer-based) and loses the ordering guarantees of message passing. Processes should communicate via `send`/`receive`, GenServer calls, PubSub, or Registry dispatch. ETS is a shared data store, not a message bus. (OTP Message Passing)
- **Check:** Flag patterns where one process writes to ETS and another process polls it in a loop.
- **Tolerate:** ETS as shared read cache (write-once-read-many), ETS for metrics counters.
- **Severity:** `info`

### 5.28 ETS Without Heir

Critical ETS tables should configure `:heir` for survival across process restarts.

- **Why:** When the owning process dies, its ETS tables are deleted — all cached data is lost. If a supervisor restarts the process, the new instance starts with an empty table. Configuring `:heir` transfers ownership to another process instead of deleting the table. (Data Persistence)
- **Check:** Flag `:named_table` ETS creation without `:heir` option in production code.
- **Tolerate:** Disposable caches that are cheap to rebuild, test tables.
- **Severity:** `info`

### 5.40 ETS Ownership Leak

ETS table created in GenServer's `init/1` without cleanup in `terminate/2`.

- **Why:** When the owning process dies and restarts, creating a new `:named_table` with the same name may crash because the old table still exists momentarily (race condition with ETS cleanup). Explicit deletion in `terminate/2` or configuring `:heir` prevents this. (Resource Management, Restart Safety)
- **Check:** Flag GenServer modules that call `:ets.new` in init but don't implement `terminate/2` or configure `:heir`.
- **Tolerate:** Non-named tables (no name collision risk), tables with heir configuration.
- **Severity:** `info`

### 5E. Process Naming & Registry

### 5.24 Dynamic Atom Names

`String.to_atom/1` called — atoms are never garbage collected.

- **Why:** Atoms live in a global table with a hard limit (default ~1,048,576). Anything that converts user input or growing strings to atoms is a memory leak: enough unique inputs and the VM crashes with "not enough atom space." Use `String.to_existing_atom/1` (fails safely) or explicit atom mapping. (Memory Safety, VM Stability)
- **Check:** Flag `String.to_atom/1` in non-test code.
- **Tolerate:** Compile-time atom creation, `String.to_existing_atom`, `Module.concat` (different mechanism).
- **Severity:** `info`

### 5.25 Custom Registry Reinvention

Custom process lookup maps reinventing what Elixir's `Registry` module already provides.

- **Why:** `Registry` handles cleanup automatically when registered processes die, supports both unique and duplicate keys, and is BEAM-optimized. A custom GenServer maintaining a `Map` of pid→name loses automatic cleanup, becomes a serialization bottleneck, and accumulates dead PIDs. (Standard Library, Reliability)
- **Check:** Flag GenServer modules that maintain a Map of pid→name or name→pid with manual insert/delete operations.
- **Tolerate:** Specialized lookup structures with semantics different from Registry.
- **Severity:** `info`

### 5.26 Global Registration

`:global` registration for local-only processes.

- **Why:** `:global` uses distributed consensus (leader election via `:global` module). For single-node process discovery, `Registry` is vastly simpler, faster, and doesn't have the edge cases of distributed registration (split-brain, network partitions). (Performance, Simplicity)
- **Check:** Flag `:global` registration in non-distributed applications.
- **Tolerate:** Applications explicitly using distributed Elixir (`Node.connect`, `Horde`).
- **Severity:** `info`

### 5.29 Singleton Bottleneck

Named GenServer handling entity-keyed requests — all requests serialized through one process.

- **Why:** A named GenServer that dispatches by entity ID (user_id, order_id) serializes all requests through one process. If you have 10,000 users, their requests queue behind each other. Use DynamicSupervisor + Registry for per-entity processes — each entity gets its own process, and requests are parallel. (Scalability)
- **Check:** Flag named GenServer modules where `handle_call`/`handle_cast` pattern-matches on an ID-like field in the message to dispatch different entities.
- **Tolerate:** Low-throughput coordination processes, rate limiters (serialization is the point).
- **Severity:** `info`

### 5.33 Unnamed Singleton

GenServer whose public API uses `__MODULE__` as the server target but `start_link` doesn't register the name.

- **Why:** If the public API calls `GenServer.call(__MODULE__, ...)` but `start_link` doesn't pass `name: __MODULE__`, the calls will fail with "no process associated with the given name" — even though the process IS running (just not registered). (Configuration Bug)
- **Check:** Flag GenServer modules where public functions reference `__MODULE__` as the server target but `start_link` doesn't pass `name: __MODULE__` or an equivalent registration.
- **Tolerate:** Modules where the name is passed dynamically via options.
- **Severity:** `info`

### 5.36 Stale PID Reference

PIDs stored in process state or ETS without `Process.monitor` — become stale after process restart.

- **Why:** PIDs reference a specific process incarnation. When that process dies (and potentially restarts with a new PID), the stored reference still points to the old dead process. Messages sent to it are silently dropped, `GenServer.call` raises an `:exit`. Without monitoring, the storing process never learns the referenced process died — leading to silent message loss and growing stale entries. Production systems (Supavisor, Finch, db_connection) always monitor PIDs they store. (Stale Reference, Silent Failure)
- **Check:** Flag `:ets.insert` with pid-like variables or state map updates with pid keys without corresponding `Process.monitor` or `Process.link` in the same function.
- **Tolerate:** PIDs managed by Registry (auto-cleanup), short-lived references in synchronous operations.
- **Severity:** `info`

### 5F. Process State & Safety

### 5.30 Process.sleep in Production

`Process.sleep/1` blocks the calling process for the specified duration.

- **Why:** Sleep blocks the entire process — in production, this means unresponsive GenServers, delayed request handling, and wasted scheduler time. For periodic work, use `Process.send_after` or `:timer.send_interval`. For rate limiting, use token buckets or GenServer state. (Performance, Responsiveness)
- **Check:** Flag `Process.sleep` in non-test, non-script files.
- **Tolerate:** Test files, seed scripts, deliberate rate limiting with documented reason.
- **Severity:** `info`

### 5.31 Unbounded State

GenServer accumulating unbounded data in process state.

- **Why:** Process state lives on the process heap. Unbounded accumulation (event logs, request history, cache without eviction, append-only lists) eventually causes out-of-memory. The BEAM can't garbage-collect live data — it's all referenced. Use ETS for growing datasets, or implement eviction. (Memory Safety)
- **Check:** Heuristic — flag GenServer state that grows via `[new | state.list]` or `Map.put` without corresponding cleanup or size limit.
- **Tolerate:** Bounded collections with explicit size limits, ETS-backed state.
- **Severity:** `info`

### 5.32 Process Dictionary

`Process.put/get` — hidden mutable state that doesn't appear in function signatures.

- **Why:** The process dictionary is invisible mutable state. It doesn't appear in `handle_call` arguments or return values, can't be inspected via `:sys.get_state`, can't be tested without running specific process setup, and survives across callback invocations without being in the state parameter. (Testability, Explicitness)
- **Check:** Flag `Process.put/2` and `Process.get/1,2` in non-infrastructure code.
- **Tolerate:** Logger metadata, OpenTelemetry context, connection pool ownership tracking.
- **Severity:** `info`

### 5.34 Unsafe Production Tracing

`:dbg` and `:erlang.trace` used without safety limits in production code.

- **Why:** `:dbg` without message limits can produce gigabytes of trace output in seconds on a production system, overwhelming logging infrastructure and filling disks. Use Rexbug or `:recon_trace` which have built-in safety limits (max messages, duration timeout, rate limiting). (Production Safety)
- **Check:** Flag `:dbg.tpl`, `:dbg.p`, `:erlang.trace` in non-test code.
- **Tolerate:** Test code, developer tooling modules, modules explicitly named "debug" or "trace".
- **Severity:** `info`

### 5.35 GenStage No Demand

GenStage consumer subscription without explicit `max_demand`/`min_demand`.

- **Why:** Default demand settings may not match the producer's capacity. Explicit values document the expected throughput contract and prevent overwhelming slow consumers with too many events at once. (Backpressure, Configuration)
- **Check:** Flag GenStage consumer `subscribe_to` or `subscribe` calls without `max_demand`/`min_demand` options.
- **Tolerate:** Simple producer-consumer pairs in low-throughput scenarios.
- **Severity:** `info`

### 5.42 Sequential Where Parallel

Sequential collection processing with I/O in the callback — candidate for `Task.async_stream`.

- **Why:** `Enum.map/each/flat_map` processing where each iteration performs I/O (HTTP, database, file) blocks sequentially. For N items with T seconds of I/O each, sequential takes N*T wall-clock time. `Task.async_stream` runs iterations in parallel, reducing wall-clock time to approximately T. Also detects sequential independent variable bindings that could use `Task.async`. (Performance, Parallelism)
- **Check:** Flag `Enum.map/each/flat_map`, `Stream.map/each/flat_map`, and `for` comprehensions where the callback body calls known I/O modules (Repo, HTTPoison, Req, Finch, Tesla, File, GenServer, Mailer, etc.). Also flag consecutive independent variable bindings that each perform I/O and don't depend on each other.
- **Tolerate:** Test files, callbacks that must run in order, rate-limited external services, already-parallel code (Task.async_stream).
- **Severity:** `info`

### 5.43 GenServer Callback Sprawl

GenServer with too many distinct `handle_call`/`handle_cast`/`handle_info` message patterns.

- **Why:** A GenServer handling 10+ distinct message types is doing too many things. It's hard to understand which messages it handles, test each message path, and reason about state transitions. Consider splitting into focused processes or extracting message handlers into modules. (Single Responsibility)
- **Check:** Count distinct first-argument patterns across all `handle_call`/`handle_cast`/`handle_info` clauses. Threshold: 10.
- **Tolerate:** Node/connection managers that legitimately proxy many operations to a single resource (e.g., a NIF handle).
- **Severity:** `warning`

### 5.44 String.to_atom in Hot Path

`String.to_atom/1` called inside GenServer callbacks or Enum callbacks.

- **Why:** The atom table is finite (~1M entries by default) and atoms are never garbage collected. `String.to_atom` in a callback that runs per-request or per-item risks exhausting the table, crashing the entire VM. Use `String.to_existing_atom/1` or explicit atom mapping. (Runtime Safety)
- **Check:** Find `String.to_atom/1` inside all loop constructs (Enum, Stream, `:lists`, `for`, `receive`, `Task.async_stream`), GenServer callbacks (`handle_call/cast/info/continue`), and recursive function bodies.
- **Tolerate:** `String.to_existing_atom` (safe). Compile-time atom creation (module attributes).
- **Severity:** `warning`

### 5.45 Named ETS Table Without Cleanup

`:ets.new` with `:named_table` in a module that has no `terminate/2` callback or `:ets.delete` call.

- **Why:** Named ETS tables are global resources. If the owning process restarts (supervisor restart), the new process can't create the same named table because the old one still exists — crash loop. `terminate/2` with `:ets.delete` ensures cleanup on graceful shutdown. (Resource Management)
- **Check:** Find `:ets.new` with `:named_table` option, check for `terminate/2` or `:ets.delete` in the same module.
- **Tolerate:** Tables created in Application.start (owned by the application, not a process). Tables with `:heir` option set.
- **Severity:** `info`

### 5.46 DETS :ordered_set Type

`:dets.open_file/2` called with `type: :ordered_set` — DETS does not support ordered sets.

- **Why:** DETS table types are `:set`, `:bag`, and `:duplicate_bag`. There is no `:ordered_set` in DETS — only ETS supports it. The call crashes at runtime with `{:error, {:badarg, ...}}` and is invisible until the code path first runs in production. The mistake is easy because ETS and DETS share most other options. (Correctness)
- **Check:** Find `:dets.open_file/2` calls whose options keyword list contains `type: :ordered_set`.
- **Tolerate:** Test files (the call is presumably exercising the error path).
- **Severity:** `warning`

### 5.47 DETS Ownership Leak

A GenServer that calls `:dets.open_file` in `init/1` (or elsewhere) without a `terminate/2` that closes the table.

- **Why:** DETS tables are on-disk files. Unlike ETS, the file persists when the owning process exits — but the file's internal state (in-flight buffer, dirty pages) is only flushed on `:dets.close/1`. A supervisor-restarted GenServer that opens the same file may face a corrupted-file recovery (`auto_repair`), data loss for unflushed writes, or `:error, :system_limit` if the previous handle wasn't closed. Always close DETS in `terminate/2`. (Resource Management, Correctness)
- **Check:** Find GenServer modules with `:dets.open_file` calls and no `terminate/2` callback.
- **Tolerate:** Plain modules (non-GenServer one-shot scripts), test files. DETS tables held by short-lived processes that aren't supervisor-restarted.
- **Severity:** `warning`

### 5.50 Unsafe Deserialization or Runtime Eval

`:erlang.binary_to_term` without `:safe`, `Code.eval_string/eval_quoted`, or `Jason.decode` with `keys: :atoms` on untrusted input.

- **Why:** ETF deserialization without `:safe` can instantiate arbitrary terms including atoms, funs, and pids — any of which can exhaust resources or trigger unexpected behaviour. `Code.eval_string/eval_quoted` execute arbitrary Elixir source — if the argument reaches attacker-controlled input this is remote code execution. `Jason.decode(json, keys: :atoms)` creates a new atom per unique JSON key, exhausting the finite atom table on untrusted input. (Security, RCE, Atom-Table Exhaustion)
- **Check:** Flag `:erlang.binary_to_term/1,2` without `[:safe]` in options; `Code.eval_string`, `Code.eval_quoted`, `Code.compile_string` calls; `Jason.decode/decode!` with `keys: :atoms` option.
- **Tolerate:** `:erlang.binary_to_term(data, [:safe])` — safe mode only allows already-existing atoms. `keys: :atoms!` raises on unknown keys (bounded set). Internal process communication over trusted channels.
- **Severity:** `error`

### 5.51 Dynamic Apply From Input

`apply/2,3` calls where the module or function is a non-literal value that may flow from external input.

- **Why:** Dynamic dispatch on a module/function name reachable by request input (controller params, channel messages, Oban args) is an RCE vector — the BEAM can invoke any loaded module/function, and `String.to_existing_atom/1` plus a registry lookup is a complete RCE primitive even against partially-validated input. (Security, RCE)
- **Check:** AST scan for `apply/2,3`. Pre-passes collect MFA-tuple destructure patterns (`{m, f, a} = ...`) and `def apply/N` heads to suppress false positives. Flags applies where the module isn't a literal `__aliases__`/`:atom` or the function isn't a literal atom.
- **Tolerate:** Variables matching the OTP MFA-tuple convention (Supervisor child specs, GenServer start_link); `Phoenix.Controller.action_name/1` injection; `apply(__MODULE__, unquote(:foo), args)` inside a macro; literal captures `&Mod.fun/N`; `def apply/N` heads.
- **Severity:** `error`

### 5.52 Stacktrace in Response

`__STACKTRACE__` reaches a response boundary (controller render, channel reply, GraphQL resolver, JSON view, LiveView flash).

- **Why:** Stacktraces leak internal module structure, line numbers, library versions, and call paths — a roadmap for an attacker. They belong in `Logger` / `:telemetry.execute`, never in the response body. Boundary modules sanitize errors into bounded codes the caller can read. (Security, Information Disclosure)
- **Check:** Scan files classified as boundary layers (`*_controller.ex`, `*_channel.ex`, `*_live.ex`, `*_view.ex`, `*_json.ex`, resolvers). Walk the AST and flag `__STACKTRACE__` references that aren't inside `Logger.*` or `:telemetry.execute/3` calls.
- **Tolerate:** `Logger.error(Exception.format(:error, e, __STACKTRACE__))`; `:telemetry.execute(_, _, %{stack: __STACKTRACE__})`; explicit drain in a custom error reporter.
- **Severity:** `error`

### 5.53 IO.inspect / dbg in `lib/`

`IO.inspect/1,2` or `Kernel.dbg/0,1` left in production code under `lib/`.

- **Why:** These are debug-print primitives — they bypass structured logging, dump unredacted internal state to stdout, and almost always indicate forgotten debug code. Production lib code logs through `Logger` with structured metadata. (Slop, Observability)
- **Check:** Walks AST in `lib/` files (excluding `priv/`, `scripts/`, `mix.exs`, tests). Flags `IO.inspect` calls (alias or fully qualified) and `dbg` calls.
- **Tolerate:** Calls in test files; calls under `priv/` or `scripts/`; a `# RULE-EXCEPTION: 5.53 — <reason>` comment within 2 lines of the call (e.g., a CLI tool whose output IS the user's screen).
- **Severity:** `warning`

### 5.54 Secret-bearing Struct Without Inspect Override

A `defstruct` includes secret-shaped fields (`:token`, `:password`, `:api_key`, etc.) without `@derive {Inspect, only/except: ...}` or a `defimpl Inspect` body.

- **Why:** Crash dumps include process state in SASL reports, observer, and remote shells. Without an Inspect override, every secret field is printed verbatim — and crash dumps often end up in monitoring systems and incident channels. (Security, Information Disclosure)
- **Check:** Per-module: detect `defstruct` definitions, match field names against a sensitive-field allowlist (`:token`, `:auth_token`, `:secret`, `:api_key`, `:password`, `:password_hash`, etc.). Verify the module also has `@derive {Inspect, ...}` or `defimpl Inspect`.
- **Tolerate:** `@derive {Inspect, only: [...]}` listing only safe fields; `@derive {Inspect, except: [sensitive...]}`; `defimpl Inspect, for: __MODULE__`. Reference: `Plug.Conn`'s `defimpl Inspect` replaces `:secret_key_base` with `:...`.
- **Severity:** `warning`

### 5.55 Async Closure Drops `Logger.metadata`

`Task.async`, `Task.Supervisor.start_child`, `Task.async_stream`, etc. spawn a closure that logs or emits telemetry without restoring `Logger.metadata`.

- **Why:** `Logger.metadata` is per-process. The spawned task starts with empty metadata — every log line and `:telemetry.execute/3` it emits is missing the parent's `request_id` / `trace_id` / `tenant_id`, becoming an orphan in log search. Capture metadata before the spawn, restore it inside the closure. (Observability, Correlation)
- **Check:** Find async entry points (`Task.async/1,2`, `Task.async_stream/3,5`, `Task.Supervisor.start_child/2`, `Task.Supervisor.async_nolink/3`). Walk each closure body for `Logger.*` or `:telemetry.execute/3` calls without an in-scope `Logger.metadata(captured)` restore.
- **Tolerate:** `parent = Logger.metadata(); Task.async(fn -> Logger.metadata(parent); ... end)`; explicit `TraceContext` struct passed into the closure as a parameter; closure that emits no observability calls.
- **Severity:** `warning`

### 5.56 Oban Worker Without Telemetry / Logger

A module declaring `use Oban.Worker` whose `perform/1` body emits no `:telemetry.*` or `Logger.*` calls.

- **Why:** Oban workers run async and out-of-band. Without telemetry or logging, you cannot tell whether a job ran, how long it took, whether it errored, or which job processed which payload. Background-work observability has to be intentional. (Observability)
- **Check:** Find `use Oban.Worker`. Extract every `def perform/1` clause. Flag if no clause calls `Logger.*` or `:telemetry.execute/3` (or `:telemetry.span/3`).
- **Tolerate:** `@archdo_no_observability` marker (declarative opt-out); presence of `Logger.*` or `:telemetry.*` in any `perform/1` clause; trivial workers documented as pure-pass-through with no behaviour worth measuring.
- **Severity:** `info`

### 5.57 LiveView Async Without `handle_async/3`

A LiveView calls `start_async/3` or `assign_async/3` but doesn't define `handle_async/3` to receive the result.

- **Why:** `start_async` schedules work and routes the result to `handle_async/3`. Without that callback, the result message is unhandled and the assign stays at its initial value forever — the user sees a blank or loading state indefinitely. (Correctness)
- **Check:** Per-file: classify as LiveView (path or `use Phoenix.LiveView`). Find `start_async/3` or `assign_async/3` calls. Verify a matching `def handle_async/3` exists.
- **Tolerate:** Async results explicitly ignored (with a comment); the async wrapped in a try/rescue at the caller; multiple async keys handled in a single `handle_async/3` clause.
- **Severity:** `warning`

### 5.58 LiveView `mount/3` Without Telemetry / Logger

A LiveView's `mount/3` body has no `:telemetry.*` or `Logger.*` call, leaving page-load events untracked.

- **Why:** `mount/3` is the LiveView equivalent of a page render. Without instrumentation, you can't measure mount latency, see which pages users visit, or correlate failures with specific routes. The Phoenix telemetry ecosystem expects mount events. (Observability)
- **Check:** Per-file: classify as LiveView. Extract every `def mount/3` body. Flag if none contain `Logger.*`, `:telemetry.execute/3`, or `:telemetry.span/3`.
- **Tolerate:** `@archdo_no_observability` marker; instrumentation in a shared `on_mount` hook that this LiveView uses; trivial LiveView with no useful mount telemetry to emit.
- **Severity:** `info`

### 5.60 `GenServer.call` Without `catch :exit`

`GenServer.call/2,3` to a registered name without a surrounding `try` / `catch :exit, _`.

- **Why:** `GenServer.call`'s failure mode is `:exit`, not a regular exception — `rescue` doesn't catch it; only `catch :exit, _` does. When the callee process is down or restarting, the caller's `call` exits, and an unguarded call propagates that exit upward. Cross-supervisor calls should survive the callee's crash. (Resilience)
- **Check:** Find `GenServer.call(name, ...)` where `name` is an alias, atom, or via-tuple (not a pid). Walk the enclosing AST: flag if not inside a `try ... catch :exit, _ ...` block or guarded by a `Process.whereis` check.
- **Tolerate:** Calls inside `try ... catch :exit, _ -> ...`; `Process.whereis(name)` with nil-check before the call; intra-supervisor calls where caller and callee crash together by design (`:one_for_all`).
- **Severity:** `info`

### 5.61 Behaviour Callback Missing `@impl true`

A behaviour callback (GenServer / Supervisor / Plug / LiveView / Oban.Worker / etc.) is defined without `@impl true` (or `@impl Module`).

- **Why:** `@impl true` is the compiler's correctness check. Without it, a typo (`hanle_call` vs `handle_call`) silently becomes a regular helper — the framework never invokes it, and the bug surfaces only at runtime when the missing callback would have been needed. (Correctness)
- **Check:** Walk the module body. Collect behaviours in scope via `use` and `@behaviour`. Resolve each to its callback-name set. Walk statements sequentially tracking the most recent `@impl` flag; flag any callback-named `def` not preceded by `@impl true` (or `@impl SomeBehaviour`).
- **Tolerate:** `@impl true` immediately above the def; `@impl ModuleName` when disambiguating multiple behaviours; user-defined helpers that happen to share the name (mark with `@archdo_not_a_callback` or rename).
- **Severity:** `warning`

### 5.62 `handle_continue` Opportunity in `init/1`

A GenServer's `init/1` does heavy synchronous work (`Repo.*`, HTTP client, `File.*`, `Process.send_after`) instead of returning `{:ok, state, {:continue, _}}`.

- **Why:** Supervisor children start sequentially. While `init/1` runs, every sibling waits — heavy I/O during init delays application boot and can timeout the supervisor. `handle_continue/2` defers the work to AFTER init returns, preserving single-threaded guarantees without blocking startup. (Performance, Boot Reliability)
- **Check:** Per-file: classify as GenServer. Walk every `def init/1` body for calls into `Repo`, `HTTPoison`, `Req`, `Tesla`, `Finch`, `File`, `Process` (heavy work). Verify the return shape is `{:ok, state, {:continue, _}}`.
- **Tolerate:** `init/1` returning `{:ok, state, {:continue, term}}` with a matching `handle_continue/2`; trivially-fast init (constant-time setup); explicit comment justifying synchronous I/O at boot.
- **Severity:** `info`

### 5.63 Sensitive State Without `format_status/1,2`

A GenServer with sensitive-named state fields lacks a `format_status` callback that redacts them before display.

- **Why:** When a GenServer crashes, OTP logs the full state. `:sys.get_state/1` exposes it on demand; `:observer` and remote IEx show it interactively. Without `format_status`, secrets appear in production logs and operator debug sessions. (Security, Information Disclosure)
- **Check:** Per-file: classify as GenServer. Extract `defstruct` fields, filter against sensitive keywords (`:password`, `:token`, `:secret`, `:api_key`, `:apikey`, `:private_key`, `:session_id`, `:auth`, `:hmac`, `:credential`). Verify the module defines `format_status/1` or `format_status/2`.
- **Tolerate:** `format_status/1,2` redacting the fields; struct-level `@derive {Inspect, except: [...]}` or `defimpl Inspect`; no sensitive-shaped fields in the state.
- **Severity:** `warning`

### 5.64 Manual `Task.async` + `Task.await` List

`Enum.map(coll, &Task.async/1) |> Enum.map(&Task.await/1)` — replacing the convenience of `Task.async_stream/3,5`.

- **Why:** The manual pattern starts every task at once — no concurrency limit, no per-task timeout, no graceful crash handling. `Task.async_stream` adds `:max_concurrency`, `:timeout`, `:on_timeout`, and `:ordered` out of the box. (Performance, Resilience)
- **Check:** Walk AST for pipe chains. Detect `Enum.map(_, &Task.async/1)` followed by `Enum.map(_, &Task.await/1)`.
- **Tolerate:** `Task.async_stream/3,5` already in use; documented justification when a manual pattern is required for custom control flow not expressible via async_stream options.
- **Severity:** `info`

### 5.65 `Task.async` Inside a GenServer

`Task.async/1,2` is invoked inside a GenServer module — its link propagates a task crash to the GenServer process itself.

- **Why:** `Task.async` returns a task linked to the caller. If the task crashes, the GenServer crashes with it — turning a single failed external call into a full-state-loss restart. The fix is `Task.Supervisor.async_nolink/3` plus `:DOWN` handling in `handle_info/2`. (Resilience)
- **Check:** Per-file: classify as GenServer. Walk AST for `Task.async/1,2` calls (qualified or aliased). Flag any occurrence inside a GenServer module body.
- **Tolerate:** `Task.Supervisor.async_nolink/3` with a corresponding `handle_info({:DOWN, ref, ...}, state)` clause; documented justification when crash-cascade is the desired behaviour (the task and GenServer represent one logical unit).
- **Severity:** `warning`

### 5.66 Registry + DynamicSupervisor under `:one_for_one`

A supervisor's child list contains both a `Registry` and a `DynamicSupervisor` under `strategy: :one_for_one`.

- **Why:** `:one_for_one` restarts only the crashed child. When `Registry` crashes and restarts (now empty), the `DynamicSupervisor`'s children still hold stale via-tuples — lookups fail, and new children can't register because of name collisions. The system enters a half-broken state until restarted manually. (Resilience)
- **Check:** Walk supervisor `init` callbacks for `Supervisor.init(_, strategy: :one_for_one)` (or `Supervisor.start_link(_, strategy: :one_for_one)`). Verify the children list contains both a `Registry` child spec and a `DynamicSupervisor` child spec.
- **Tolerate:** `strategy: :rest_for_one` with `Registry` listed before `DynamicSupervisor`; `strategy: :one_for_all`; `Registry` and `DynamicSupervisor` in separate sub-supervisors with `:one_for_all`.
- **Severity:** `warning`

### 5.67 `Oban.Worker` Without `unique:`

`use Oban.Worker, ...` without a `unique:` option, allowing duplicate enqueues to execute as separate jobs.

- **Why:** Oban automatically retries jobs and producers may retry on transient failure. Without `unique:`, a producer-side retry (network blip, request retry, double-click) becomes a duplicated job execution. With `unique:` plus an idempotent `perform/1`, the system gets at-least-once delivery that behaves like exactly-once. (Resilience, Correctness)
- **Check:** Find `use Oban.Worker, opts`. Inspect the keyword list for a `unique:` key.
- **Tolerate:** `unique: [period: ..., fields: [...]]` set to a sensible value; documented justification when the worker is genuinely safe to run multiple times in parallel (idempotent upsert with a content-addressed primary key).
- **Severity:** `info`

### 5.68 `Oban.Worker` Without `max_attempts:`

`use Oban.Worker, ...` without a `max_attempts:` option, relying on a global default.

- **Why:** Retry policy is part of the worker's contract. Leaving `max_attempts` implicit means the policy is set far from the worker's design — idempotent webhook delivery may want 20+ retries; non-idempotent payment should be 1. Tuning the global default necessarily affects every other worker. (Correctness)
- **Check:** Find `use Oban.Worker, opts`. Inspect the keyword list for `max_attempts:`.
- **Tolerate:** Explicit `max_attempts: N` per worker; documented decision to rely on global default for a class of trivial workers.
- **Severity:** `info`

### 5.69 GenServer-wrapped Counter Increment

A GenServer `handle_call/3` whose only effect is `state.field + 1` (or similar pure increment) is ~100× slower than `:counters` / `:atomics`.

- **Why:** `:counters` and `:atomics` are lock-free, live outside any process, and are designed for this. Every caller updates them without sending a message. A GenServer-wrapped counter is also a single-process bottleneck under load; `:counters` scales with cores. (Performance)
- **Check:** Per-file: classify as GenServer. Find `def handle_call/3` whose body is purely `{:reply, _, <state-with-incremented-field>}`. Detect `state + N`, `%{state | field: state.field + 1}`, or arithmetic-only state updates.
- **Tolerate:** `:counters.new/:atomics.new` already in use; `:persistent_term` for read-mostly counters; documented case where the GenServer holds counter PLUS other state that genuinely needs serialization.
- **Severity:** `info`

### 5.70 `Process.send_after(self(), :tick, T)` Loop With Constant T

A `handle_info(:tick, _)` re-arms via `Process.send_after(self(), :tick, T)` where T is a compile-time constant.

- **Why:** `:timer.send_interval(N, msg)` schedules a recurring message at fixed intervals from BEAM's `:timer` server — non-drifting. The send_after-rearm idiom drifts: each tick measures from when the previous `handle_info` ran, not from the previous tick's scheduled time. For constant cadence, `:timer.send_interval` is simpler and more accurate. (Correctness)
- **Check:** Per-module: collect every `handle_info` message atom. Collect `Process.send_after(self(), msg, constant)` calls. Match them up — flag the rearming pattern with constant delay.
- **Tolerate:** Variable delays (exponential backoff, jitter); cancellable timers (one-shot ticks where you need the timer reference); `:timer.send_interval` already in use; Oban.Cron for long intervals.
- **Severity:** `info`

### 5.71 `Application.get_env` in GenServer Callback

`Application.get_env/2,3` (or `fetch_env/2`, `fetch_env!/2`) inside `handle_call/3`, `handle_cast/2`, `handle_info/2`, or `handle_continue/2`.

- **Why:** Application env lookup is fast but on hot paths (every message) the value can be cached. Capture the value in `init/1` and store it in state, OR use `:persistent_term` for runtime-changing values. Repeated lookups reduce throughput and signal an unintentional config dependency. (Performance, Hot Path)
- **Check:** Walk `def handle_call`/`handle_cast`/`handle_info`/`handle_continue` bodies for `Application.get_env`, `Application.fetch_env`, `Application.fetch_env!` calls.
- **Tolerate:** Config captured in `init/1` and stored in state; `:persistent_term.put` at boot read in callbacks; rare-path fallback (e.g. one specific message kind) where the lookup overhead is genuinely irrelevant.
- **Severity:** `info`

### 5.72 `:gen_tcp` / `:gen_udp` / `:ssl` Socket With `active: true`

A socket is opened with `active: true`, delivering all incoming data to the owning process's mailbox without backpressure.

- **Why:** `active: true` sends every received packet to the owner's mailbox as fast as the network delivers — a fast or hostile peer can fill the mailbox unboundedly, exhausting memory and crashing the node. `active: :once` (the default) and `active: N` give backpressure: receive a frame, process it, re-arm. (Resilience, DoS Protection)
- **Check:** Find `:gen_tcp.listen/connect/accept`, `:gen_udp.open`, `:ssl.listen/connect` calls. Inspect their option lists for `active: true`.
- **Tolerate:** `active: :once`; `active: N` for batched protocols; `active: false` (passive `recv`); documented case where `active: true` is genuinely safe for a known-rate trusted peer.
- **Severity:** `warning`

### 5.73 `:gen_tcp.recv/2` / `:ssl.recv/2` Without Timeout

A receive call (or `connect`) is invoked without an explicit timeout, defaulting to `:infinity`.

- **Why:** The network's primary failure mode is silence — load balancers black-hole, peers half-close, servers slow to a crawl. An explicit timeout converts indefinite blocking into `{:error, :timeout}` that the caller can handle (retry, fall back, surface incident). `:infinity` produces a process that wedges forever and can't be diagnosed. (Resilience)
- **Check:** Find `:gen_tcp.recv/2`, `:gen_tcp.connect/3`, `:ssl.recv/2`, `:ssl.connect/3` calls. Verify the timeout argument is provided.
- **Tolerate:** Explicit timeout argument tied to the protocol's SLO; documented case where `:infinity` is acceptable (test code, trusted internal-only channel).
- **Severity:** `info`

### 5.74 Inline Effect in a Building-Block Module

A module whose `@moduledoc` advertises building-block status performs side effects (`Logger`, `Phoenix.PubSub`, `Repo`, `:telemetry.execute`, ETS or `:persistent_term` writes) inside function bodies.

- **Why:** Building-block functions must be pure (same input → same output) so Archdo's Blackbox analyzer can score them, callers can trust them, and property-based tests cover them. Side effects belong in the orchestrator that calls the building block, not inside it. (Composability, Purity)
- **Check:** Per-file: classify as building-block-claimed by checking the `@moduledoc` for "building block" / "building-block". Walk all function bodies for `Logger.*`, `Phoenix.PubSub.broadcast`, `Repo.*` writes, `:telemetry.execute/3`, `:ets.insert/update/delete`, `:persistent_term.put`.
- **Tolerate:** Drop the building-block claim from the `@moduledoc` (the module is an orchestrator); move the effects to a wrapping orchestrator and keep the building block pure; `Logger.debug` strictly inside `if Mix.env() == :dev`.
- **Severity:** `info`

### 5.75 Memoize Opportunity in Building-Block Function

A building-block function calls an expensive constructor (`Regex.compile`, `Jason.decode`, `:crypto.hash`, `DateTime.from_iso8601`, etc.) on a literal argument every invocation.

- **Why:** Compiling a regex, parsing JSON, or hashing a constant produces the same result every call. Hoisting to a module attribute or `:persistent_term` (set at boot) avoids wasted CPU on hot paths. Building-blocks frequently sit inside loops and request handlers. (Performance)
- **Check:** Per-file: classify as building-block. Walk function bodies for `Regex.compile*`, `Jason.decode*`, `:crypto.hash`, `DateTime.from_iso8601*`, `NaiveDateTime.from_iso8601*` whose first argument is a string literal or compile-time-known atom.
- **Tolerate:** `@compiled_regex Regex.compile!("...")` at module top-level; `:persistent_term.put` at boot; documented case where recompilation is necessary (e.g., the literal may change at hot-reload time).
- **Severity:** `info`

### 5.76 Inline HTTP in LiveView `handle_event/3`

A LiveView's `handle_event/3` calls a blocking HTTP client (`Tesla`, `Req`, `HTTPoison`, `Finch`, `:httpc`) directly, freezing the LiveView process for all other events while the request is in flight.

- **Why:** A LiveView is a single GenServer per user session. While `handle_event/3` runs, no other event is processed — clicks queue up, the UI feels frozen, and a single slow API call hangs the entire session. Wrap the HTTP call in `start_async/3` or `assign_async/3`. (Performance, User Experience)
- **Check:** Per-file: classify as LiveView. Find `def handle_event/3` and walk its body, skipping the children of async wrappers (`start_async`, `assign_async`, `Task.async*`). Flag direct HTTP-client calls. Project-level: build a transitive taint set via the function graph (depth ≤ 5) to catch indirect HTTP wrappers.
- **Tolerate:** HTTP calls inside `start_async/3`, `assign_async/3`, `Task.async/1,2`, or `Task.async_stream` lambdas; HTTP calls in an orchestrator module that the LiveView dispatches to via `start_async`; documented case for synchronous HTTP (extremely rare, e.g., transactional rollback).
- **Severity:** `warning`

---

## 6. Module Quality

### 6A. Size & Complexity

### 6.1 Module Cohesion

Module with too many public functions — suggests mixed responsibilities.

- **Why:** A module with 30 public functions is doing too many things. It's hard to understand (which functions relate to each other?), hard to test (large setup for each test context), and hard to maintain (changes cascade through unrelated functions). Split into focused modules. (Single Responsibility)
- **Check:** Count public `def` functions (excluding framework callbacks). Flag above threshold.
- **Tolerate:** Context facade modules (designed to have many public functions as the domain's API surface), macro-generated functions.
- **Severity:** `info` / `warning`

### 6.2 Function Complexity

High cyclomatic complexity or excessive arity.

- **Why:** Functions with many branches (case, cond, if, with — each adding a path through the code) are hard to test exhaustively. High arity (>5 parameters) signals too many responsibilities packed into one function. Both indicate the function should be decomposed. (Complexity, Testability)
- **Check:** Compute cyclomatic complexity per function (count case/cond/if/with branches). Flag above threshold (default: 9). Also flag arity > 5.
- **Tolerate:** Pattern-matching dispatch across multiple clauses (each clause is simple, the complexity is in the dispatch).
- **Severity:** `info`

### 6.3 Struct Field Count

Structs with too many fields suggest the data model should be decomposed.

- **Why:** A struct with 25 fields is hard to construct correctly, hard to pattern-match partially, and hard to maintain. Nested structs (Address, Metadata, Settings) break it into focused shapes that each have their own validation and documentation. (Data Design)
- **Check:** Count `defstruct` fields. Flag above threshold.
- **Tolerate:** Ecto schemas (may legitimately map wide database tables).
- **Severity:** `info` / `warning`

### 6.4 Module Length

File length as an architecture signal — long files do too much.

- **Why:** Files over 1000 lines are hard to navigate and typically contain mixed concerns. Over 2000 lines almost certainly have multiple responsibilities that should be in separate modules. Below ~1000 the line count is too noisy to be a useful signal — Phoenix-generated context modules and internal protocols/parsers/code generators routinely sit in the 500–1000-line band while remaining cohesive. (Readability, SRP)
- **Check:** Count source lines per file. 1000 = info, 2000 = warning.
- **Tolerate:** Generated files, comprehensive test files with many test cases, internal protocols / parsers / code generators that are genuinely one large unit.
- **Severity:** `info` / `warning`

### 6.5 Function Fan-Out

Individual functions depending on too many distinct modules.

- **Why:** A function that calls 10 different modules is an orchestration point that's hard to test (many dependencies to mock) and hard to understand (too many concepts in one place). (Coupling)
- **Check:** Count distinct module references per function using FunctionGraph. Flag above threshold.
- **Tolerate:** Facade functions that intentionally coordinate across modules.
- **Severity:** `info`

### 6.12 Responsibility Clustering

Module has independent function clusters suggesting multiple responsibilities.

- **Why:** If a module's public functions form 2+ disconnected clusters (user_* functions never call order_* functions and vice versa), the module has multiple responsibilities that happen to share a file. They should be separated into focused modules. (Single Responsibility, Cohesion)
- **Check:** Build an intra-module call graph of public→private function calls. Detect disconnected components.
- **Tolerate:** Small modules with few functions, thin facade modules.
- **Severity:** `info`

### 6B. Naming & Design

### 6.6 Boolean Flag Arguments

Functions with boolean parameters — `do_thing(true)` is opaque at the call site.

- **Why:** `process_order(order, true)` is unreadable at the call site. The reader must look up the function signature to understand what `true` means. `process_order(order, validate: true)` (keyword option) or `process_and_validate_order(order)` (separate function) communicates intent. (Readability)
- **Check:** Flag functions where a boolean argument controls an `if` branch inside the body — the boolean is a hidden dispatch mechanism.
- **Tolerate:** Simple predicate wrappers, internal helpers not exposed as public API.
- **Severity:** `info`

### 6.7 Pretentious Names

Module names containing Manager, Helper, Util, Service, Handler hide what the module actually does.

- **Why:** These suffixes describe the relationship to other code, not what the module does. "OrderHelper" could contain anything — the name provides zero information. "OrderPriceCalculator" or "OrderValidator" describes the responsibility. (Naming)
- **Check:** Flag module names ending in Manager, Helper, Util, Utils, Service, Handler, Base.
- **Tolerate:** Framework-conventional names where the suffix has a specific meaning (EventHandler in Broadway, ChannelHandler in Phoenix).
- **Severity:** `info`

### 6.8 Distance from Main Sequence

Robert C. Martin's package metrics (Ca/Ce/I/A/D) — modules far from the main sequence are problematic.

- **Why:** A module that many others depend on (high stability, low instability) but has no abstractions (no behaviours, no protocols — low abstractness) is in the "Zone of Pain": concrete and stable, meaning it's hard to change without breaking many dependents. The main sequence is the optimal line where abstractness and instability balance. (Robert C. Martin Metrics)
- **Check:** Compute Ca (afferent coupling — who depends on me), Ce (efferent coupling — who do I depend on), I (instability = Ce/(Ca+Ce)), A (abstractness = abstract elements / total elements), D (distance = |A + I - 1|). Flag modules with D > threshold.
- **Tolerate:** Small utility modules, configuration modules.
- **Severity:** `info`

### 6.17 Nesting Depth

Deeply nested control flow (>4 levels of case/with/if/cond) — extract functions to flatten.

- **Why:** Each nesting level (case inside with inside if) adds a branch the reader must track mentally. Beyond 3-4 levels, the code becomes a maze that's hard to follow and nearly impossible to test all paths. Extract inner branches into named private functions — each becomes independently readable and testable. (Readability, Testability)
- **Check:** Walk AST counting nesting depth of control flow constructs (case, cond, if, with, try). Flag functions exceeding the threshold.
- **Tolerate:** Pattern matching in function heads (not counted as nesting).
- **Severity:** `info`

### 6.19 If/Else for Structural Dispatch

`if/else` used to dispatch on data shape or type instead of multi-clause functions or case.

- **Why:** Elixir's multi-clause functions and `case` expressions handle structural dispatch more clearly than `if/else` chains. Pattern matching is exhaustive (the compiler warns on missing clauses), self-documenting (each clause shows the shape it handles), and extensible (add a clause, don't modify a condition). `if/else` hides the dispatch inside a boolean expression and doesn't compose. (Idiomatic Elixir, Elixir Skill Rule 1)
- **Check:** Flag `if is_map(x) do ... else ... end`, `if is_nil(x) do ... else ... end`, and similar type-guard if/else patterns where both branches return values. Also flags `if x != nil do ... else ... end`.
- **Tolerate:** `if` without `else` (side-effect only — idiomatic), simple boolean conditions that aren't structural dispatch.
- **Severity:** `info`

### 6C. Error Handling

### 6.9 Rescue Swallows Error

Bare rescue clauses that swallow errors silently — catch everything, do nothing useful with it.

- **Why:** Elixir's error handling philosophy is "let it crash" for processes (supervisors restart them) and ok/error tuples for function-level errors. A bare rescue that swallows exceptions combines the worst of both worlds: the error is not propagated (so callers can't handle it), the process doesn't crash (so the supervisor doesn't restart it), and no log is produced (so nobody knows it happened). Silent failures accumulate into mysterious behaviour that's impossible to debug. (Error Visibility, Let It Crash)
- **Check:** Flag rescue clauses that catch wildcards (`_` or `_e`) and don't log, reraise, or return `{:error, _}`.
- **Tolerate:** Rescue clauses that log the error, return `{:error, reason}`, or reraise.
- **Severity:** `warning`

### 6.10 Raise in Non-Bang Function

Non-bang functions should return ok/error tuples, not raise exceptions.

- **Why:** Elixir convention: `fetch/1` returns `{:ok, _}` or `{:error, _}`, `fetch!/1` raises. A non-bang function that raises breaks this convention — callers must add try/rescue when they expected pattern matching on the return value. This defeats the ok/error pattern and makes error handling inconsistent. (API Convention, Elixir Skill Rule 2)
- **Check:** Flag public functions not ending in `!` that contain `raise` without a surrounding `rescue` block.
- **Tolerate:** Framework callbacks where raising is the "let it crash" convention (handle_init, handle_pad_added, handle_info, handle_call, terminate — whitelisted), setup/validation functions (`init`, `validate!`).
- **Severity:** `warning`

### 6.11 Inconsistent Error Shape

Module mixes ok/error tuples with raises, nils, and bare returns across its public API.

- **Why:** A module where `fetch/1` returns `{:ok, _}`, `get/1` returns nil, and `create/1` raises has three different error conventions. Callers must read every function's implementation to know how to handle failure. This multiplies the mental overhead of using the module. Pick one style per module. (Consistency, Predictability)
- **Check:** Classify each public function's error style (ok/error, raises, returns_nil, bare). Flag modules with 3+ distinct styles.
- **Tolerate:** Bang/non-bang pairs (intentional — the module provides both), modules with only 1-2 public functions.
- **Severity:** `info`

### 6.14 Try/Rescue for Expected Failures

`try/rescue` wrapping a bang function where the non-bang variant already returns ok/error tuples.

- **Why:** `try do Repo.get!(User, id) rescue Ecto.NoResultsError -> nil end` is an exception round-trip — raising an exception then immediately converting it back into a value. `Repo.get(User, id)` already returns nil without the exception overhead. The try/rescue pattern also catches more than intended: a bug in the try body that raises the same exception type is silently swallowed. (Idiomatic Elixir, Performance, Elixir Skill Rule 2)
- **Check:** Flag try/rescue blocks that contain bang function calls (`get!`, `decode!`, `insert!`) and catch specific exceptions.
- **Tolerate:** Test code, cases where no non-bang alternative exists.
- **Severity:** `warning`

### 6.15 Bang in Ok/Error Function

Functions returning ok/error tuples should not call bang functions that can raise.

- **Why:** When a function establishes an ok/error contract (returns `{:ok, _}` or `{:error, _}`), callers expect failures to come back as `{:error, reason}`, not as raised exceptions. A bang call inside this function breaks that contract — the caller's `case` or `with` never sees the error branch because the bang raises before the function can return `{:error, _}`. The caller must add a try/rescue, defeating the purpose of the ok/error API. (Contract Violation)
- **Check:** Flag public functions that return ok/error tuples AND contain bang calls to non-stdlib modules.
- **Tolerate:** `init`, `start_link` (setup contexts), `struct!` (programmer error, not runtime failure), seed/migration files.
- **Severity:** `info`

### 6.16 Missing Rescue at System Boundary

System boundary calls need rescue/catch, not just ok/error — the boundary IS where exceptions are expected.

- **Why:** Two specific patterns require exception handling (not ok/error):
  1. `GenServer.call(variable_pid, msg)` — raises an `:exit` (not an exception) when the target process has died. `rescue` doesn't catch exits; you need `catch :exit`. LiveView, Oban, and db_connection all use this pattern.
  2. `:erlang.binary_to_term(data)` on untrusted input — raises `ArgumentError` on malformed data. This is a system boundary where the input is external and may be anything.
- **Check:** Flag `GenServer.call(variable, ...)` without `catch :exit`, and `:erlang.binary_to_term` without `rescue`. Skip calls to `__MODULE__` (can't die during call).
- **Tolerate:** Calls to atom-named servers (known to be registered), calls inside supervised processes where crash-and-restart is acceptable.
- **Severity:** `info` / `warning`

### 6.18 Exception Laundering

Rescue catches one exception type but raises a different one — original stacktrace is lost.

- **Why:** When a rescue clause catches ExceptionA but raises ExceptionB, the original stacktrace and error context are lost. Debugging becomes harder because the error reported at the surface doesn't match the root cause. If you need to wrap exceptions, use `reraise/2` to preserve the stacktrace, or return `{:error, reason}` to let the caller decide. (Debuggability, Stacktrace Preservation)
- **Check:** Flag rescue clauses that catch a specific exception type AND raise a different exception type (not `reraise`).
- **Tolerate:** Rescue clauses using `reraise` (preserves stacktrace), rescue clauses returning ok/error tuples.
- **Severity:** `info`

### 6D. Recursion

### 6.20 Non-Tail Recursion

Recursive function where the call is not in tail position — risks stack overflow on large input.

- **Why:** Tail-call optimization (TCO) reuses the stack frame when the recursive call is the last expression — constant memory regardless of depth. A tail-recursive function runs in constant memory — it can loop indefinitely without growing the stack. This is the BEAM's fundamental mechanism for process main loops, state machines, iterative algorithms, and any repeated execution. When the call is NOT last (e.g., `[head | recurse(tail)]` — the cons operation happens after the recursive return), each call adds a stack frame. On large input, this overflows the stack. (Stack Safety, Elixir Skill: "Operations after the call break TCO")
- **Check:** Flag recursive functions where the self-call appears inside a cons `[_ | recurse(_)]`, append `_ ++ recurse(_)`, or arithmetic `_ + recurse(_)`.
- **Tolerate:** Tree traversal (inherently non-tail but bounded by tree depth, not list length). Tail-recursive process loops, state machines, and iterative algorithms (e.g., `poll_loop/2`, `retry_loop/3`, GenServer-style receive loops) — these are correct and fundamental BEAM patterns.
- **Severity:** `info`

### 6.21 Unnecessary Manual List Recursion

`[head | tail]` + `[]` base case pattern where Enum functions would suffice.

- **Why:** Elixir's Enum module handles list iteration with `map`, `reduce`, `filter`, `flat_map`, and 50+ other functions. Manual recursion with `[head | tail]` for simple collection processing is more code, harder to read, and easy to get wrong (non-tail position, missing base case). Use Enum for collection processing. Use recursion for: (a) tail-recursive process loops, state machines, and iterative algorithms — `receive` loops, retry loops, convergence — where the function continues until a condition is met; (b) tree/graph traversal; (c) early termination with complex multi-accumulator state; (d) `Stream.unfold` or `Stream.resource` alternatives. Tail-recursive functions are the BEAM's fundamental mechanism for all repeated execution — process loops, state machines, iterative algorithms, and stream processing. They run in constant memory via TCO. (Idiomatic Elixir, Elixir Skill Rule 6)
- **Check:** Flag multi-clause functions where one clause matches `[head | tail]` and calls itself with tail, and another clause matches `[]` as the base case.
- **Tolerate:** Tree/graph traversal (recursion IS the right tool), multi-accumulator patterns, functions that need early termination with complex conditions, **tail-recursive loops** (process loops, state machines, retry/poll/receive patterns — these are correct BEAM patterns, not unnecessary recursion).
- **Severity:** `info`

### 6.22 Broken Tail-Call Optimization

Recursive function appears tail-recursive but TCO is silently defeated by surrounding code.

- **Why:** Tail-recursive functions are the BEAM's fundamental looping and continuation mechanism — used for process main loops, state machines, iterative computation, stream processing, and any repeated execution — they run in constant stack space via TCO. Three patterns break TCO without changing the apparent structure:
  1. `try/rescue/catch` wrapping the recursive call — the BEAM must keep the stack frame to unwind on exception
  2. Pipe after the call — `recurse(t, acc) |> IO.inspect()` runs the pipe operation after return
  3. Binary operation after the call — `recurse(t, acc) <> suffix` runs concatenation after return
  
  The function works perfectly on small input (the stack is big enough) but crashes with stack overflow on large data. The developer thinks they've written a tail-recursive function because it has an accumulator. (Silent Stack Overflow, Elixir Skill: "try/rescue/catch blocks prevent TCO")
- **Check:** Flag recursive functions where the self-call is inside a try/rescue/catch block, piped into another function, or used as an operand in a binary expression.
- **Tolerate:** Non-recursive functions (no self-call to break).
- **Severity:** `warning`

### 6.23 Unbounded Recursion

Recursive function without depth guard or finite base case — stack overflow risk on large/malicious input.

- **Why:** Non-tail recursive functions consume one stack frame per call (unlike tail-recursive functions which run in constant space via TCO). Without a depth guard (e.g., `when depth < @max_depth`) or a guaranteed finite base case (matching `[]` or `0`), the recursion depth depends entirely on the input. If the input comes from outside the system (user data, API response, file content), a malicious or malformed input can crash the process with a stack overflow. (Input Safety, Defensive Programming)
- **Check:** Flag non-tail recursive functions that lack: (1) a finite base case matching `[]` or `0`, (2) a depth guard parameter with numeric comparison, (3) struct pattern matching (tree walk — bounded by known structure). Only applies to functions that ARE recursive and NOT tail-recursive.
- **Tolerate:** Tail-recursive functions (safe at any depth), list recursion with `[]` base case (bounded by input length), tree walks with struct patterns.
- **Severity:** `info`

### 6E. Compiled Analysis

### 6.24 Dead Public Function *(compiled)*

Public function exported but never called from outside the module.

- **Why:** Public functions are part of a module's API contract. An exported function nobody calls is dead weight — it increases the API surface, survives refactors that should have removed it, and misleads developers. (Dead Code Elimination, API Clarity)
- **Check:** Build compiled call graph from beam files. Find exported functions with zero external callers. Exclude framework callbacks (init, handle_call, mount, render, etc.) and behaviour callbacks.
- **Tolerate:** Library API functions called by external consumers, dynamically called functions (apply/3, protocol dispatch).
- **Severity:** `info`

### 6.25 Transitively Dead Function *(compiled)*

Function only called from dead functions — removing the dead callers would make this unreachable.

- **Why:** This function has callers, but every caller is itself dead code (rule 6.24). The entire call chain is dead. (Transitive Dead Code, Call Graph Analysis)
- **Check:** Walk outward from dead roots in the compiled call graph. If all callers of a function are dead, the function is transitively dead. Only checks project modules, not stdlib.
- **Tolerate:** Same as 6.24.
- **Severity:** `info`

### 6.26 Oversized API Surface *(compiled)*

Module exports many functions but less than 25% are called by external modules.

- **Why:** A module with many exports but few external callers has an oversized public API. Every exported function is a contract. Functions only used internally should be `defp`. (Minimal API Surface, Encapsulation)
- **Check:** Count external callers per exported function. Flag modules with ≥8 exports where <25% are used externally.
- **Tolerate:** Library modules designed for external consumption, utility modules with intentionally broad APIs.
- **Severity:** `info`

### 6.27 Non-Exhaustive Public API *(compiled)*

Public function has multiple clause patterns but no catch-all — crashes with FunctionClauseError on unexpected input.

- **Why:** A public API function pattern-matching on specific shapes without a fallback clause will crash if called with unexpected input. For internal dispatch this is fine (let it crash), but public API functions should handle all inputs gracefully or document their constraints. (API Robustness, Defensive Programming)
- **Check:** Extract function clauses from beam abstract code. Flag exported functions with ≥2 clauses where no clause is a catch-all (all args are variables with no guards).
- **Tolerate:** Functions where the restricted input set is by design (dispatch tables, type-specific handlers), internal functions that are public for technical reasons.
- **Severity:** `info`

### 6.28 Inconsistent API Return Shapes *(compiled)*

Public function returns different shapes from different clauses.

- **Why:** A function returning `{:ok, _}` from one clause and `:ok` from another forces callers to handle all possible shapes. Consistent return shapes make the API predictable and pattern-matchable. (API Consistency, Contract Clarity)
- **Check:** Classify return expressions from each clause in beam abstract code. Flag functions where clauses return different shape categories. Excludes `{:ok, _} | {:error, _}` which is a valid standard pattern.
- **Tolerate:** Functions where varying return shapes are intentional and documented with `@spec`.
- **Severity:** `warning`

### 6.29 Stub Function

Function body is a placeholder that will fail at runtime — `raise "not implemented"`, TODO, or similar.

- **Why:** Stub functions are useful during development but dangerous in production. They crash or silently misbehave when the code path is reached. (Production Readiness, Code Completeness)
- **Check:** Flag function bodies containing: `raise "not implemented"`, `raise "TODO"`, `IO.warn("not implemented")`, or returning `:not_implemented`. Skip test files.
- **Tolerate:** Test helpers, intentionally unsupported behaviour callbacks with `@doc` explaining why.
- **Severity:** `warning`

### 6.30 Degenerate Function *(compiled)*

Public function always raises or returns a fixed value regardless of input — likely a stub surviving macro expansion.

- **Why:** After all macros expand, this function's compiled body is degenerate — it either always raises or every clause returns the same fixed atom. This catches stubs injected by macros that aren't visible in source code. (Post-Expansion Stub Detection)
- **Check:** Analyze beam abstract code. Flag exported functions where all clauses either raise or return the same literal. Exclude OTP callbacks (init, terminate, etc.) and single-clause `:ok` returns (normal side-effect functions).
- **Tolerate:** OTP callbacks, side-effect functions that legitimately return `:ok`.
- **Severity:** `info` (warning for "not implemented" raises)

### 6.31 Lookup Table Candidate *(compiled)*

Function is a pure literal-to-literal mapping — equivalent to a Map lookup.

- **Why:** Multi-clause functions that map literal values to literal values with no computation are functionally equivalent to `Map.fetch!/2`. Replacing with a module attribute map is more concise, self-documenting, and can be more efficient (O(log n) map lookup vs O(n) clause matching for large tables). The data becomes extractable for documentation or serialization. (Data vs Code, Clarity)
- **Check:** Analyze beam abstract code. Flag functions where ≥3 clauses all have literal-only patterns (atoms, integers, strings, tuples of literals) and literal-only return values. Also detects single-clause functions with a `case` body that is a lookup table.
- **Tolerate:** Small dispatch tables (2 clauses), functions expected to gain guards or logic later.
- **Severity:** `info`

### 6.32 Buried try/rescue

try/rescue block buried inside an anonymous function, Enum callback, or Task callback — should be extracted to a named function.

- **Why:** A try/rescue hidden inside a lambda or Enum.map callback obscures the error handling intent. The rescue clause silently converts exceptions to fallback values, making bugs invisible. Extracting to a named function (like `safe_process/1`) makes the fault isolation visible at the call site and documents that exceptions are expected. Named functions are also testable independently and reusable. (Clarity, Error Handling Visibility, Testability)
- **Check:** Flag try/rescue blocks inside: `Enum.map/flat_map/each/reduce` callbacks, `Task.async/async_stream` callbacks, or standalone `fn -> ... end` expressions. Does not flag try/rescue in named private functions (correct pattern) or try/after (cleanup pattern).
- **Tolerate:** try/rescue in named private functions — this IS the correct pattern. The rule specifically targets the anonymous/inline form.
- **Severity:** `info`

### 6F. Code Slop & Simplification

### 6.33 LLM-Generated Code Slop

Detects five patterns of unnecessarily verbose code typically generated by LLMs: `@doc` on private functions, trivial delegation wrappers, redundant boolean comparisons (`== true`), empty doc strings, and single-step pipelines.

- **Why:** LLMs produce code that compiles but is verbose, over-abstracted, or uses non-idiomatic patterns. These patterns clutter the codebase and signal code that wasn't reviewed by an experienced Elixir developer. (Code Quality, Idiomatic Elixir)
- **Check:** Five sub-checks: `@doc` before `defp`, `defp foo(x), do: Bar.foo(x)` trivial wrapper, `x == true`/`x == false`, empty `@doc ""`, single `|>` pipe.
- **Tolerate:** `defdelegate` (intentional public delegation). Multi-step pipelines (2+ pipes are idiomatic).
- **Severity:** `info`

### 6.34 Dead Private Function

Private function is never called within its module.

- **Why:** A `defp` that is never called is dead code — cognitive load, increased module size, and a possible missing call (typo or refactoring leftover). (Dead Code)
- **Check:** Extract all private function definitions, collect all bare calls and function captures (`&func/N`) from function bodies, flag definitions with no matching calls. Scans `~H` sigils for HEEx template function references.
- **Tolerate:** Functions named `__*__` (compiler-generated). `sigil_*` functions. Metaprogrammed function names (`unquote`).
- **Severity:** `warning`

### 6.35 Unreachable Clause

Catch-all clause (`_` or bare variable) appears before more specific clauses in a `case` expression.

- **Why:** A catch-all that isn't the last clause makes everything below it unreachable — dead code that looks like it's handling something. (Dead Code, Correctness)
- **Check:** Walk `case` expressions, find catch-all patterns before the last clause. Also check `cond` where `true ->` appears before the last clause.
- **Tolerate:** Pattern matching with guards (the catch-all may have a guard that makes it non-exhaustive).
- **Severity:** `warning`

### 6.36 Redundant Guard Recheck

Function body re-checks a type that's already guaranteed by the pattern match or guard.

- **Why:** When a function head matches `%{} = x`, calling `is_map(x)` in the body is redundant — the pattern already guarantees the type. (Dead Code, Clarity)
- **Check:** Extract type guarantees from patterns (`%{}` → map, `[_ | _]` → list, `<<>>` → binary) and guards (`when is_map(x)`), then walk body for redundant `is_*` checks on guaranteed variables.
- **Tolerate:** Guards on struct fields that add narrower constraints.
- **Severity:** `info`

### 6.38 Identity Transformation

No-op function call that returns its input unchanged.

- **Why:** `Enum.map(list, fn x -> x end)` or `Enum.filter(list, fn _ -> true end)` are identity operations that waste CPU cycles and obscure intent. (Dead Code, Performance)
- **Check:** Detect `Enum.map(_, fn x -> x end)`, `Enum.map(_, & &1)`, `Enum.filter(_, fn _ -> true end)`, `Enum.reject(_, fn _ -> false end)`.
- **Tolerate:** None — these are always removable.
- **Severity:** `info`

### 6.39 Defensive Nil Return

`case` expression with 3+ clauses where the last is `_ -> nil`.

- **Why:** A catch-all returning bare `nil` is a silent swallowing pattern — unexpected values disappear instead of crashing visibly. Usually indicates the developer wasn't sure what all the possible values are. (Error Handling, Fail Fast)
- **Check:** Flag `case` with 3+ clauses where the last clause is `_ -> nil`.
- **Tolerate:** 2-clause case (the catch-all IS the logic). `_ -> :error` or `_ -> {:error, _}` (meaningful error handling).
- **Severity:** `info`

### 6.40 Verbose Ok/Error Unwrap

`case` that matches `{:ok, val} -> val; {:error, _} -> nil` — swallows the error and returns nil.

- **Why:** This pattern silently discards the error reason. The caller gets `nil` with no way to know WHY it failed. Use `with` for chaining or propagate the error. (Error Handling Visibility)
- **Check:** Detect `case` with exactly `{:ok, val} -> val` and `{:error, _} -> nil` clauses.
- **Tolerate:** Functions documented as returning `nil` on failure (e.g., cache lookups).
- **Severity:** `info`

### 6.41 Single-Clause With

`with` expression with only one `<-` clause.

- **Why:** `with` is designed for chaining 2+ failable operations. A single-clause `with` is just a verbose `case`. The `case` is more explicit about what happens for each branch. (Idiomatic Elixir, Clarity)
- **Check:** Count `{:<-, _, _}` clauses in `with` expressions. Flag when exactly 1.
- **Tolerate:** None — single-clause `with` is always replaceable by `case`.
- **Severity:** `info`

### 6.42 Constant Expression

Conditional with a constant/literal condition (`if true`, `if false`, `cond` with `true` as first clause).

- **Why:** A constant condition means one branch is always taken — the other is dead code. Usually a debugging leftover or a feature flag that was never removed. (Dead Code)
- **Check:** Detect `if true/false`, `cond` where `true ->` is the first clause with more clauses after it.
- **Tolerate:** `cond do ... true -> default end` as the LAST clause (idiomatic default).
- **Severity:** `info`

### 6.43 Long Parameter List

Public function with 5+ parameters.

- **Why:** Functions with many parameters are hard to call correctly — callers must remember the order and meaning of each argument. Use a map, keyword list, or struct to group related parameters. (Usability, Readability)
- **Check:** Count arity of public functions. 5+ = info, 7+ = warning.
- **Tolerate:** NIF interfaces (arity dictated by the native function). Framework callbacks.
- **Severity:** `info` (5+), `warning` (7+)

### 6.44 Nested Control Flow

`with` inside `with`, or 3+ levels of nested `case`/`cond`/`if`/`with`.

- **Why:** Deeply nested control flow is hard to follow and test. Each nesting level adds a branch the reader must track. Extract named functions to flatten the structure. (Readability, Testability)
- **Check:** Walk function bodies tracking nesting depth of `case/with/cond/if`. Flag `with` inside another control construct, or 3+ levels.
- **Tolerate:** Pattern matching in function heads (nesting there is fine).
- **Severity:** `info`

### 6.45 Boolean Blindness

Public non-predicate function returns bare `true`/`false` for a failable operation.

- **Why:** Functions named `validate`, `check`, `verify`, `authorize` that return bare booleans prevent callers from knowing WHY the operation failed. Returning `{:ok, _}/{:error, reason}` communicates the failure mode. (Error Handling, API Design)
- **Check:** Find public functions whose name starts with `validate/check/verify/authorize/authenticate/confirm/ensure`, does not end with `?`, and returns only `true`/`false`.
- **Tolerate:** Predicate functions (`?` suffix). Functions that genuinely have boolean semantics.
- **Severity:** `info`

### 6G. Performance Traps

### 6.46 String Concatenation in Loop

`<>` string concatenation inside `Enum.reduce` or `for` comprehension with string accumulator — O(n²).

- **Why:** Each `<>` concatenation copies the entire accumulated string. For a list of n items this is O(n²). Build an IO list instead: collect `[part | acc]` and call `IO.iodata_to_binary/1` once at the end. (Performance)
- **Check:** Find reduce with string init and `<>` in callback body — covers `Enum.reduce`, `Stream.transform`, `:lists.foldl/foldr`, and `for ... reduce: ""`. Also flags `<>` concatenation in GenServer callbacks and recursive functions.
- **Tolerate:** Small known-size inputs (< 10 items). String interpolation (`#{}`) which is optimized by the compiler.
- **Severity:** `warning`

### 6.47 Collection Empty Check via length/1

`length(list) == 0`, `length(list) > 0`, `Enum.count(list) == 0` — traverses the entire collection to check emptiness.

- **Why:** `length/1` and `Enum.count/1` are O(n) — they traverse the entire list. Checking emptiness is O(1) with pattern matching: `match?([_ | _], list)` for non-empty, `match?([], list)` for empty. (Performance)
- **Check:** Detect `length(x) == 0`, `length(x) > 0`, `Enum.count(x) == 0`, `Enum.count(x) != 0`.
- **Tolerate:** `length(x) > N` where N > 0 (genuinely need the count). `Enum.count(x, fun)` without comparison.
- **Severity:** `info`

### 6.48 Map.keys/values |> length()

`Map.keys(m) |> length()` or `length(Map.keys(m))` — O(n) when `map_size/1` is O(1).

- **Why:** `Map.keys/1` materializes all keys into a list (O(n) time and memory), then `length/1` traverses it (another O(n)). `map_size/1` returns the count in O(1) from the map's internal metadata. (Performance)
- **Check:** Detect `Map.keys/values |> length`, `length(Map.keys/values(...))`, `Enum.count(Map.keys/values(...))`.
- **Tolerate:** When the actual keys/values list is needed (not just the count).
- **Severity:** `info`

### 6.49 Regex Literal in Hot Path

`~r/pattern/` inside Enum callbacks or GenServer callbacks.

- **Why:** Regex sigils in function bodies may be recompiled each call. Hoisting to a module attribute (`@pattern ~r/.../ `) compiles once at compile time. (Performance)
- **Check:** Find `{:sigil_r, _, _}` inside all loop constructs (Enum, Stream, :lists, for, receive, Task.async_stream), GenServer callbacks, and recursive function bodies.
- **Tolerate:** Module-level `@attr ~r/.../` (already compiled once). Infrequently-called functions.
- **Severity:** `info`

### 6.50 Inefficient List Operation

Operations that ignore Elixir's linked-list O(n) characteristics.

- **Why:** Elixir lists are singly-linked — head access is O(1) but append, random access, and last-element access are O(n). Seven sub-checks: `list ++ [item]` (append), `acc ++ list` in reduce (growing accumulator), `Enum.at(list, 0)` (use `hd`), `List.last` in loop, `Enum.reverse |> hd` (use `List.last`), `List.insert_at(list, -1, item)` (hidden append), `Enum.at(list, variable)` in loop (random access), `List.delete_at` in loop. (Performance, Data Structure Awareness)
- **Check:** Pattern-match AST for each sub-check. `++` accumulator only checked in `Enum.reduce/reduce_while` (not in `flat_map`/`map` where it joins local variables).
- **Tolerate:** Small known-size lists. AST traversal on fixed-structure nodes.
- **Severity:** `warning` (append/accumulator), `info` (others)

### 6.51 Collection Traversal Waste

Collection operations with more efficient alternatives.

- **Why:** Five sub-checks: `Enum.count(list, fun) > 0` should be `Enum.any?` (short-circuits), `Enum.filter |> Enum.map` should be a `for` comprehension (two passes → one), `Enum.sort |> hd` should be `Enum.min` (O(n log n) → O(n)), `Enum.reverse(Enum.reverse(x))` is identity (pure waste), `Enum.member?` on list in loop should use MapSet (O(n) → O(1) per lookup). (Performance)
- **Check:** AST pattern matching for each sub-check. Pipe detection handles both 2-step and 3-step pipe forms.
- **Tolerate:** `Enum.count` without comparison (genuinely need the count). `Enum.sort` followed by `Enum.take(n)` where n > 1.
- **Severity:** `warning` (Enum.member? in loop), `info` (others)

### 6.52 String.length for Empty/Size Check

`String.length(s) == 0` or `String.length(s) > 0` — O(n) grapheme traversal for an O(1) check.

- **Why:** `String.length/1` counts Unicode graphemes by traversing the entire string. Checking `s == ""` is O(1). `byte_size(s) == 0` is also O(1) and works in guards. (Performance)
- **Check:** Detect `String.length(s) == 0`, `String.length(s) > 0`, `String.length(s) != 0`.
- **Tolerate:** `String.length(s) > N` where N > 0 (genuinely need grapheme count).
- **Severity:** `info`

### 6.53 Keyword Lookup in Loop

`Keyword.get/fetch` inside Enum callbacks — O(n) per lookup.

- **Why:** Keyword lists are stored as `[{key, value}]` tuples. `Keyword.get` scans linearly. Inside a loop of m iterations with a keyword list of n entries, this is O(m*n). Convert to Map once (O(n)) then use `Map.get` (O(log n)). (Performance)
- **Check:** Find `Keyword.get/fetch/fetch!/has_key?/get_lazy` inside all loop constructs: Enum (28 functions), Stream (17 functions), `:lists` (17 functions), `for` comprehensions, `receive` blocks, `Task.async_stream`, GenServer callbacks, and recursive function bodies.
- **Tolerate:** `Keyword.get` outside loops. Small keyword lists (< 5 entries).
- **Severity:** `info`

### 6H. Pattern Matching Quality

### 6.54 Shadowed Clause

A broader pattern appears before a more specific pattern in function heads or case clauses, making the specific clause unreachable.

- **Why:** Elixir matches clauses top-to-bottom. When an earlier clause's pattern is a superset of a later clause's pattern, the later clause is dead code — it can never execute. Unlike 6.35 (catch-all before last), this rule detects subtler shadowing: `%{}` before `%{key: _}`, `{:ok, _}` before `{:ok, %User{}}`, or map with fewer key constraints before map with more. These are usually clause ordering bugs, not intentional fallbacks. (Correctness, Dead Code)
- **Check:** For multi-clause functions: group clauses by {name, arity}, compare each pair for pattern subsumption — catch-all variables, empty map before keyed/struct, tagged tuples with broader values, maps with fewer keys. For case expressions: same pairwise subsumption check. Guard-aware: clauses with guards are not considered catch-alls (the guard narrows the match). Disjoint type guards (e.g., `is_binary` vs `is_list`) are recognized as non-overlapping. Clauses >50 lines apart are skipped (likely compile-time branches). Variable reuse across params (`def f(x, x)`) is recognized as an equality constraint, not a catch-all.
- **Tolerate:** Guarded clauses (guards narrow the match). Different literal atoms/integers in the same position. Clauses in different compile-time branches (`if Code.ensure_loaded?(...) do ... else ... end`).
- **Severity:** `warning`

### 6I. Eager Evaluation

### 6.55 Over-Eager Evaluation

Computing more than needed — transforming entire collections when only a subset is used.

- **Why:** Six sub-checks that catch unnecessary work: (1) `Enum.map |> Enum.take(n)` transforms all elements then discards most, (2) `Enum.map |> hd` transforms all to use one, (3) `Enum.to_list |> Enum.filter` materializes a stream defeating lazy evaluation, (4) `Enum.map |> length/Enum.count` builds a mapped list then discards it (map doesn't change count), (5) `Repo.all |> length` loads all rows from DB to count them (use `Repo.aggregate(:count)`), (6) `Enum.map |> Enum.find` transforms all elements to find one. (Performance, Resource Waste)
- **Check:** AST pattern matching for pipe chains and nested calls. Detects both `a |> b |> c` pipe form and `c(b(a))` nested form. For Repo.all, matches any module ending in `Repo`.
- **Tolerate:** When the full mapped list is also used elsewhere (not just counted/taken). Stream pipelines that correctly terminate lazily.
- **Severity:** `info` (most), `warning` (Repo.all |> length — database round-trip waste)

### 6J. Information Exposure

### 6.56 Sensitive Data Exposure

Sensitive data (passwords, tokens, API keys) may be exposed through logs, encoders, error messages, or crash reports.

- **Why:** Six sub-checks: (1) Struct with sensitive-named fields (password, token, secret, api_key, etc.) but no `@derive {Inspect, only: [...]}` — crash reports and `IO.inspect` will expose them, (2) `@derive Jason.Encoder` without `:only` on a struct with sensitive fields — API responses include passwords, (3) `IO.inspect`/`inspect()` called on variables named `password`, `credentials`, `token`, `secret`, (4) `Logger` calls that interpolate sensitive-named variables, (5) hardcoded strings that match known API key formats (`sk_live_*`, `ghp_*`, `xoxb-*`, `AKIA*`, `eyJ*`) or module attributes with sensitive names containing string values, (6) `raise` messages interpolating sensitive variables. (Security, Compliance, OWASP)
- **Check:** Field name matching against a curated list of 30+ sensitive field names. String prefix matching for known API key formats. Variable name heuristics for log/raise interpolation. `@derive` analysis for both Inspect and Jason.Encoder protocols.
- **Tolerate:** Test files (test fixtures may contain fake credentials). Structs with `@derive {Inspect, only: [...]}` already configured. Short strings matching prefixes (< 12 chars — likely pattern constants, not real keys).
- **Severity:** `warning` (hardcoded secrets, overbroad Jason.Encoder), `info` (missing Inspect derive, logger/raise interpolation)

### 6.57 Inefficient Filter (Repo Then Enum.filter)

`Repo.list-returning-call(...) |> Enum.filter(predicate)` — the predicate could move into the database query.

- **Why:** Fetching every row and then filtering in Elixir uses more DB I/O, more network bandwidth, and more memory than letting the database apply the predicate server-side. The DB has indexes; Elixir's `Enum.filter` doesn't. (Performance, Database)
- **Check:** AST walk for pipelines shaped `<Repo list-returning call>(...) |> Enum.filter(<inline predicate>)`. Matches `all`, `preload`, `stream`, `stream_preload` piped to `Enum.filter` with an inline capture or `fn`.
- **Tolerate:** Remote function references (`&MyApp.fun/1`) opaque to introspection; `@archdo_intentional_filter` marker; test files.
- **Severity:** `info`

### 6.58 Telemetry in Recursive Function

`:telemetry.execute/3` or `:telemetry.span/3` at the top level of a self-recursive function emits per-iteration.

- **Why:** Telemetry handlers run synchronously in the calling process. Naive emit-per-iteration in a tight loop multiplies runtime by orders of magnitude when handlers are non-trivial (logging, metrics export). Emit ONCE around the recursion entry point, not at every step. (Performance)
- **Check:** AST walk over function definitions. Detects top-level (sibling-of-recursion, not behind `if`/`case`/`cond`) `:telemetry.execute/3` or `:telemetry.span/3` calls in functions that also recurse on themselves.
- **Tolerate:** Telemetry inside conditional branches (only emits sometimes); non-recursive functions; `@archdo_intentional_recursive_telemetry` marker.
- **Severity:** `info`

### 6.59 Callback Hell (4+ Nested Anonymous Functions)

More than 3 levels of nested `fn ... end` or `&...` captures.

- **Why:** Each level captures bindings from its parent, so reading the innermost body requires tracking N parent scopes. Real-world code at this depth tends to have bugs around variable shadowing and unintended captures, and it's nearly impossible to step through with `dbg`. Extract intermediate names. (Readability, Maintainability)
- **Check:** AST walk counting nesting depth of `fn` and `&` nodes. Flags the outermost node whose subtree contains a chain of 4+ nested closures.
- **Tolerate:** Three or fewer levels (the threshold); pipelines that look nested but operate on distinct values; macro contexts where the AST is generated.
- **Severity:** `info`

### 6.60 `Enum.reduce` With `throw` / `catch` for Early Exit

A `try` block whose body uses `Enum.reduce` and `throw` to break out early.

- **Why:** `Enum.reduce_while/3` was added precisely for early termination — it returns `{:cont, acc}` to continue or `{:halt, acc}` to stop, with no exception machinery. The throw/catch idiom works but adds runtime cost (exception construction, stack unwinding) and obscures the reducer's halt condition. (Idiomatic Code, Performance)
- **Check:** AST walk for `try` blocks with `catch` clauses whose body contains `Enum.reduce` and at least one `throw` inside the reducer.
- **Tolerate:** Try/catch around other unrelated code; reducers that don't throw; documented case where `reduce_while` doesn't fit (rare).
- **Severity:** `info`

### 6.61 `cond` Without Catch-All Clause

A `cond do ... end` block with no `true ->` (or other catch-all) terminal clause.

- **Why:** Elixir does not auto-default a `cond` whose conditions all evaluate falsy — the result is `CondClauseError` at runtime when the unmatched-input path runs. Convention is to terminate every `cond` with `true -> default` so the structure is total over its input space. (Safety, Robustness)
- **Check:** AST walk over `cond` nodes. Extract the clause list. Flag any `cond` whose clauses don't end with a truthy literal guard (`true`, `:ok`, non-zero number, etc.).
- **Tolerate:** Deliberate partial-function patterns where the unmatched case is documented to be impossible (rare); `cond` in macro-generated code where coverage is proven elsewhere.
- **Severity:** `warning`

### 6.62 Multiple Pipes on One Line

Two or more `|>` operators sharing a single source line.

- **Why:** A pipeline is a sequence of transformations on a primary subject — each step has its own intent. Putting multiple pipes on one line collapses the visual structure, defeats the readability that pipelines exist to provide, and forces the reader to mentally re-parse the chain. Canonical Elixir form: subject on its own line, then one `|>` per step on its own line. (Readability, Convention)
- **Check:** AST walk collects all `|>` nodes and groups by source line. Flags lines with 2+ pipes.
- **Tolerate:** Macro-generated pipes (rare); documented case where compactness matters more than line layout.
- **Severity:** `info`

### 6.63 `(fn x -> ... end).()` Should Be `then/2`

A pipeline applies an anonymous function via the immediate-call form `(fn x -> ... end).()`.

- **Why:** `Kernel.then/2` was added for exactly this case — applying a non-first-arg-compatible function to the piped value. The `(fn ... end).()` form predates `then/2`. `then/2` reads as "now do this with the value" and matches the rest of the pipeline's visual rhythm. (Idiomatic Code, Readability)
- **Check:** AST walk for pipelines where the RHS is `{:., _, [{:fn, _, _}]}` applied — i.e., immediately invoking an anonymous function.
- **Tolerate:** Non-pipeline contexts (not flagged); intentional anonymous-function application not in a pipeline.
- **Severity:** `info`

### 6.64 Bind-Then-Side-Effect-Then-Return Should Be `tap/2`

A function body that binds a variable, runs a side effect referencing it, then returns it unchanged.

- **Why:** `Kernel.tap/2` was added for this exact shape: "do something with this value, then continue with the value unchanged". The bind-side-effect-return form predates `tap/2`. Using `tap/2` makes the side-effect role explicit (the value flows through unchanged). (Idiomatic Code, Readability)
- **Check:** AST walk over function definitions. Looks for body shape: assignment `x = ...`, middle statement that mentions `x` (the side effect), final statement that returns `x` unchanged.
- **Tolerate:** Multi-statement sequences with multiple roles; side effects already wrapped in dedicated helpers; non-matching shapes.
- **Severity:** `info`

### 6.65 `Enum.zip` + `Enum.map` Should Be `Enum.zip_with/3`

`Enum.zip(a, b) |> Enum.map(fn {x, y} -> f.(x, y) end)` — two passes over the data.

- **Why:** `Enum.zip_with/3` (Elixir 1.12+) was designed for combining elements from parallel collections in one pass. Lower allocation cost, shorter notation. (Performance, Idiomatic Code)
- **Check:** AST walk for pipelines where the LHS ends in `Enum.zip/2,3` and the RHS is `Enum.map`.
- **Tolerate:** Zip followed by operations other than direct map destructuring (legitimate alternative transforms).
- **Severity:** `info`

### 6.66 `Enum.group_by + length` Should Be `Enum.frequencies_by/2`

`Enum.group_by(...) |> Map.new(fn {k, v} -> {k, length(v)} end)` builds the full grouping list just to count.

- **Why:** `Enum.frequencies_by/2` was added for this exact case — it avoids materializing the full grouping list when only the counts matter. Lower memory, single pass, shorter notation. (Performance, Memory)
- **Check:** AST walk for pipelines where LHS ends in `Enum.group_by` and RHS is `Map.new` whose function destructures `{k, v}` and returns `{k, length(v)}` with the same variable names.
- **Tolerate:** Grouping where values are used for purposes beyond counting; non-matching shapes.
- **Severity:** `info`

### 6.67 `{Enum.filter, Enum.reject}` Pair Should Be `Enum.split_with/2`

`{Enum.filter(coll, pred), Enum.reject(coll, pred)}` — same collection, same predicate, two traversals.

- **Why:** `Enum.split_with/2` returns `{kept, dropped}` from a single pass — same return shape as the filter/reject tuple at half the iteration cost. (Performance, Idiomatic Code)
- **Check:** AST walk for 2-tuples where one element is `Enum.filter(coll, pred)` and the other is `Enum.reject(coll, pred)` with the same collection and predicate (AST-equality comparison with metadata stripped).
- **Tolerate:** Filter and reject on different collections; predicates that genuinely differ; non-tuple usages.
- **Severity:** `info`

### 6.68 `Enum.find` + Transform Should Be `Enum.find_value/2,3`

`Enum.find(coll, pred) |> transform()` — predicate-then-extract that drops nil-on-not-found into the transform.

- **Why:** `Enum.find_value/2,3` was designed for the find-then-extract pattern. The predicate-and-extract collapse into one function: `fn x -> condition && extract(x) end`. Eliminates an explicit nil-handling step downstream and makes the intent ("return the first usable extraction") explicit. (Idiomatic Code, Clarity)
- **Check:** AST walk for pipelines where LHS ends in `Enum.find` and RHS is a transform step (local call, remote call, or capture — but NOT `case`/`if`/`with` which are explicit nil-handling idioms).
- **Tolerate:** Explicit nil-handling patterns (`case`/`if`/`with` after `Enum.find`); find followed by control flow rather than transformation.
- **Severity:** `info`

### 6.69 `Enum.map` Then `List.flatten` Should Be `Enum.flat_map/2`

`Enum.map(coll, f) |> List.flatten()` — two passes when one would do.

- **Why:** `Enum.flat_map/2` is the canonical form for "transform each element to a list, then concatenate the results". Single pass, lower allocation, intent obvious from the function name. (Performance, Idiomatic Code)
- **Check:** AST walk for pipelines where LHS ends in `Enum.map` and RHS is `List.flatten/1` or `:lists.flatten/1`.
- **Tolerate:** Map followed by flatten where the intermediate list is genuinely needed elsewhere.
- **Severity:** `info`

### 6.70 `Enum.map` Then `MapSet.new` Should Be `MapSet.new/2`

`Enum.map(coll, f) |> MapSet.new()` — builds an intermediate list.

- **Why:** `MapSet.new/2` accepts a transformer for exactly this case. Single pass, no intermediate list, shorter notation. Same idea as `Map.new/2` for maps. (Performance, Idiomatic Code)
- **Check:** AST walk for pipelines where LHS ends in `Enum.map` and RHS is `MapSet.new/0,1`.
- **Tolerate:** Map followed by `MapSet.new` where the intermediate list is used separately; non-matching shapes.
- **Severity:** `info`

### 6.71 `%{}` Pattern Matches Any Map

A function head pattern uses `%{}` (the open-map pattern), which matches ANY map regardless of size.

- **Why:** In Elixir, the `%{}` literal in a pattern is the open-map pattern: it matches every map. A common bug is treating it as a literal-empty-map check, which it is not. To dispatch on "empty vs non-empty map", use a `when map_size(m) == 0` guard. (Correctness, Pattern Matching)
- **Check:** AST walk over function definitions. Inspect each argument pattern; flag `{:%{}, _, []}`.
- **Tolerate:** Deliberate open-map catchalls where any-map matching is the intent; pattern matching where the empty-map fallthrough behaviour is intentional and documented.
- **Severity:** `warning`

### 6.72 `if Map.has_key?(m, k), do: Map.get(m, k)` Should Be `Map.fetch/2`

A double-lookup pattern reconstructing what `Map.fetch/2` returns natively.

- **Why:** `Map.fetch/2` is the canonical "get-or-fail" form for maps — it returns `{:ok, value}` or `:error`, which is exactly the data the has_key? + get pattern is reconstructing manually. Single hash-lookup, single well-known shape, composes cleanly with `with` chains. (Performance, Idiomatic Code)
- **Check:** AST walk for `if Map.has_key?(m, k), do: Map.get(m, k) ...` shapes (or `Map.fetch!`) where map and key arguments match (AST equality with metadata stripped).
- **Tolerate:** Conditionals where the get is absent; different map or key arguments; intentional double-lookup with a documented reason.
- **Severity:** `info`

### 6.73 Repeated Compound Guard Chain

The same `when ... and ... and ...` guard chain appears across 2+ function heads.

- **Why:** `defguard` (and `defguardp`) were added so guard chains can be named and reused. Repeating the same chain across many function heads couples them: changing the rule means editing every head, and a skipped head silently drifts. A named guard centralizes the rule. (Maintainability, DRY)
- **Check:** AST walk over function definitions. Extract each function's guard. Group compound guards (2+ predicates joined by `and`/`or`) by AST shape (metadata-stripped). Flag the first occurrence of any guard repeated 2+ times.
- **Tolerate:** Single-predicate guards; guards used only once; intentional inline patterns where naming would obscure rather than clarify.
- **Severity:** `info`

### 6.74 `Enum.filter(&match?)` + `Enum.map` Should Be `for` Comprehension

`Enum.filter(coll, &match?(p, &1)) |> Enum.map(fn p -> body end)` — filter-then-destructure that splits a single semantic into two passes.

- **Why:** `for pattern <- coll, do: body` silently skips elements that don't match the pattern, then destructures matching ones in the body. Single pass, no intermediate list, no duplicate `match?` + destructure pair to keep in sync. (Performance, Idiomatic Code)
- **Check:** AST walk for pipelines where LHS ends in `Enum.filter` with a `&match?(pattern, &1)` capture predicate and RHS is `Enum.map`.
- **Tolerate:** Filter-map patterns where the filter predicate is not a `match?` capture; non-matching shapes.
- **Severity:** `info`

### 6.75 Atom-Key Pattern in Controller / LiveView Action

A controller or LiveView action callback pattern-matches atom-keyed maps against external params, which arrive string-keyed.

- **Why:** In Elixir, atom keys (`:id`) and string keys (`"id"`) are distinct in patterns. Phoenix `params` always arrive as `%{"id" => "42"}`. A pattern of `%{id: id}` matches only if the map contains a literal atom key `:id`, which `params` does not — the action body never runs, and the framework usually picks up the next clause or falls through to a 404. (Correctness, Framework Integration)
- **Check:** AST walk over function definitions in controller / LiveView files (filename match, `use Phoenix.Controller`, or `uses_live_view?`). Check known action callback names (`index`, `show`, `new`, `create`, `edit`, `update`, `delete`, `mount`, `handle_params`, `handle_event`); flag heads that pattern-match atom-keyed maps in the request data position.
- **Tolerate:** String-keyed patterns (correct); atom-keyed matches in non-action functions (different binding source); explicit conversion via `Plug.Conn.assign` before the pattern.
- **Severity:** `warning`

### 6.76 Whole-Struct Destructure When Only One Field Is Read

A function head destructures a whole struct (`%Struct{} = var`) but only reads one field in the body.

- **Why:** Head-pattern destructuring is more declarative than body field-access — it makes the function's input contract explicit at a glance. Future readers don't have to scan the body to discover that only `id` is used. (Readability, Documentation)
- **Check:** AST walk over function definitions. Detect open-struct patterns binding the whole struct to a variable. Walk the body; count distinct field accesses (`var.field`) and total uses of `var`. Flag when exactly one field is read AND `var` is used exactly once.
- **Tolerate:** Multi-field reads (struct destructure justified); whole-struct patterns where the bound struct is also re-emitted; macro contexts.
- **Severity:** `info`

### 6.77 Body Type-Check + Raise Should Be a Head Guard

`unless is_X(arg), do: raise(...)` (or `if not is_X(arg), do: raise(...)`) at the top of a function body.

- **Why:** Head guards are part of the function's pattern-match contract. Dispatching mismatches to the next clause (or producing `FunctionClauseError`) is more uniform than raising `ArgumentError` from the body. Head guards also enable multi-clause dispatch — type-correct callers go to one clause, type-incorrect callers to a fallback or error clause. (Design, Uniformity)
- **Check:** AST walk over function definitions WITHOUT head guards. Walk the body; detect `unless is_X(arg), do: raise(...)` or `if not is_X(arg), do: raise(...)` where `is_X` is a type predicate (`is_atom`, `is_binary`, `is_integer`, `is_list`, `is_map`, `is_tuple`, `is_struct`, etc.).
- **Tolerate:** Range / value-domain checks (legitimately different from type checks); functions with head guards already; intentional body-level validation with a custom exception.
- **Severity:** `info`

### 6.78 `try/rescue` Around a Raising Call With a Safe Alternative

A `try`/`rescue` wraps a `!`-suffixed standard-library call when a non-raising sibling exists.

- **Why:** `try`/`rescue` is for genuinely-exceptional cases. When the standard library exposes a `{:ok, _} | :error` (or `{:ok, _} | {:error, _}`) sibling, that's the canonical "expected-failure" path. Pattern-matching on the result composes with `with` chains; rescue does not. (Idiomatic Code, Composability)
- **Check:** AST walk for `try` blocks. Walk the body for raising calls with known safe alternatives: `String.to_integer` → `Integer.parse`, `Map.fetch!` → `Map.fetch`, `Repo.get!` → `Repo.get`, `File.read!` → `File.read`, etc.
- **Tolerate:** `try`/`rescue` for genuinely-exceptional cases (no listed safe alternative); test rescue patterns; documented case where rescue is the right choice.
- **Severity:** `info`

### 6.79 Variable-Time Comparison of a Secret

`==` or `===` where one side is a variable whose name suggests a secret (token, hmac, signature, api_key, etc.).

- **Why:** `==` short-circuits at the first mismatched byte, making comparison time correlate with prefix-match length. Attackers measure response time and binary-search the secret. `Plug.Crypto.secure_compare/2` runs in time proportional to the LONGER of the two strings, regardless of where mismatches occur — the canonical constant-time primitive in Elixir. (Security, Cryptography)
- **Check:** AST walk for `==` and `===` comparisons. Inspect both sides; flag if either is a variable whose name (case-insensitive) contains `token`, `hmac`, `digest`, `signature`, `api_key`, `apikey`, `secret`, `session_id`, `csrf`, `password_hash`.
- **Tolerate:** Non-secret comparisons; comparisons in test/development-only code where timing leaks don't matter; a documented `Plug.Crypto.secure_compare/2` already in use.
- **Severity:** `warning`

### 6.80 Silent Rescue

A `rescue` clause whose body is a bare silent return (`nil`, `:error`, `false`, `true`, `{:error, _literal}`) with no `Logger` call and no `reraise`.

- **Why:** Silent rescues lose the exception's message and stacktrace, making production debugging impossible. Even when the caller's API accepts a nil/error fallback, the operator still needs the original exception details to diagnose the failure. (Observability, Error Handling)
- **Check:** AST walk over `try` blocks. Inspect `rescue` clauses; flag when the body is a bare silent literal (or a block ending in one) and contains no `Logger.*` call and no `reraise`. Skips test files.
- **Tolerate:** Rescues that log the exception (`Logger.error(Exception.format(:error, e, __STACKTRACE__))`); rescues that `reraise`; intentional supervisor-style swallowing of expected exceptions documented inline.
- **Severity:** `warning`

### 6.81 Chained `Map.put` Should Be `Map.merge`

Three or more consecutive `Map.put` calls on the same map.

- **Why:** Each `Map.put` traverses the map's hash structure separately. `Map.merge/2` does it in one pass and groups all the changes at one read site, making intent clearer and execution faster. (Performance, Readability)
- **Check:** AST walk over pipe chains. Detect runs of `Map.put` on the same LHS; count consecutive puts. Flag when count ≥ 3.
- **Tolerate:** Conditional puts where each depends on the prior result; puts inside a reduce/loop accumulator; macro-generated put chains.
- **Severity:** `info`

### 6.82 Fetch-Modify-Put Should Be `Map.update`

`Map.put(m, k, ...Map.get(m, k)... )` — two map lookups for one logical update.

- **Why:** `Map.update/4` and `Map.update!/3` combine the fetch and put into a single hash lookup, with the closure receiving the current value. The fetch-modify-put shape is two lookups and obscures the "I'm updating this key based on its current value" intent. (Performance, Idiomatic Code)
- **Check:** Find `Map.put` calls; walk the value-expression argument for a `Map.get` or `Map.fetch!` whose `m` and `k` arguments match the put.
- **Tolerate:** Conditional transformations where the get and put are guarded separately; complex value expressions with intentional side effects between fetch and put.
- **Severity:** `info`

### 6.83 Multiple `Keyword.get` Calls Should Be `Keyword.validate!/2`

Three or more `Keyword.get` calls on the same options variable inside a single function.

- **Why:** `Keyword.validate!/2` documents accepted keys, provides defaults, and rejects unknown keys at the function boundary — one call instead of scattered `Keyword.get` invocations. The validate-once form fails fast on typos that scattered gets would silently accept. (API Design, Correctness)
- **Check:** Per-function: count `Keyword.get` calls on each variable. Flag when any single variable has 3+ gets.
- **Tolerate:** Lazy / conditional option access where validation isn't appropriate; a single or two-key options API where validate is overkill.
- **Severity:** `info`

### 6.84 `Jason.decode` With `keys: :atoms` (Atom-Table DoS)

`Jason.decode(json, keys: :atoms)` (or `decode!`) creates an atom for every JSON key.

- **Why:** Atoms are never garbage-collected. An attacker submitting JSON with arbitrary keys can exhaust the bounded atom table (default ~1M) and crash the BEAM. Use `keys: :atoms!` (raises on unknown atom — bounded set) or the default string keys. (Security, Stability)
- **Check:** Find `Jason.decode/decode!` calls. Inspect the options keyword for `keys: :atoms` (NOT `:atoms!`). Skips test files.
- **Tolerate:** `keys: :atoms!`; default string keys; trusted internal-only configuration files with bounded known-safe key sets.
- **Severity:** `warning`

### 6.85 Logger Interpolation With `inspect` Should Use Lazy Closure

A `Logger.X` call whose first argument is an interpolated string containing an `inspect/1,2` call.

- **Why:** Non-lazy `Logger.X` evaluates the argument even when the log level is disabled — `inspect` runs (formatting potentially-large structures) and the result is discarded. The lazy form `Logger.X(fn -> ... end)` only runs when the level is enabled. On hot paths with debug-level inspects, the difference is significant. (Performance)
- **Check:** AST walk for `Logger.debug/info/warning/error/notice/critical` calls whose first argument is an interpolated string (`{:<<>>, _, parts}`); detect `inspect` references inside any interpolation expression.
- **Tolerate:** Pre-formatted strings without `inspect`; structured-metadata logging (`Logger.info("event", metadata: ...)`); already-lazy closure forms.
- **Severity:** `info`

### 6.86 One-Line Forward Should Be `defdelegate`

A public `def` whose body is a single remote call to another module with arguments passed through unchanged.

- **Why:** `defdelegate name(args), to: Mod` expresses the forward intent in one line, inherits `@spec` and `@doc` from the target, and signals to readers "this is a thin pass-through." (Idiomatic Code, Readability)
- **Check:** Per-public-def: head has only bare-variable args, no guards. Body is a single `{:., _, [{:__aliases__, _, _}, _]}` call passing the same args in the same order.
- **Tolerate:** Forwards that add transformation, logging, or error wrapping in the body; cross-namespace API translation; functions that pre-process arguments before forwarding.
- **Severity:** `info`

### 6.87 `@doc false` on `def` Should Be `defp`

A public `def` is preceded by `@doc false`, which hides it from documentation but does NOT make it private.

- **Why:** `@doc false` only affects documentation generation; the function remains public and exportable. External callers can still invoke it. `defp` is the actual privacy mechanism. The combo signals confused intent: "I want this hidden but also reachable from anywhere." (Clarity, API Design)
- **Check:** Walk module statements sequentially. Track `@doc false` markers; flag the next `def` (not `defp`) unless it's a known framework callback (GenServer, Plug, Phoenix.LiveView, Oban.Worker, etc.), follows the `__name__/arity` cross-module-internal convention, has another arity with a real `@doc`, or its body is a schema-accessor exposing a module attribute.
- **Tolerate:** Framework callbacks (their behaviours dispatch via `apply/3`, so they MUST be public); `__name__/N` cross-module-internal convention (Phoenix, Plug, Module); overload-with-shared-docs (one arity has `@doc "..."`, others have `@doc false`); schema accessors (`def opts_schema, do: @opts_schema`).
- **Severity:** `info`

### 6.88 Boolean-Returning Function Missing `?` Suffix

A public function with 2+ clauses that all return literal `true` or `false`, but whose name doesn't end in `?` (or `!`).

- **Why:** Elixir convention: predicate functions (yes/no questions) end in `?`. Without it, callers can't tell at a glance whether `valid?/1` returns a boolean or perhaps a different shape. The convention is enforced by Credo and observed throughout the stdlib (`is_*`, `*?`, `Kernel.match?/2`, etc.). (Convention, Idiomatic Code)
- **Check:** Group public functions by `{name, arity}`. Inspect every clause's return; if all return `true` or `false` literals AND the name doesn't end in `?` or `!`, flag the definition.
- **Tolerate:** Bang functions (`!` suffix already present); legacy public APIs where renaming would break downstream code (document and rename in next major version).
- **Severity:** `info`

### 6.89 Two `System.system_time` Calls With Subtraction (Use Monotonic Time)

A function calls `System.system_time/0,1` twice and subtracts.

- **Why:** `system_time` is wall-clock time and is affected by NTP adjustments and operator changes — a backward jump produces negative durations or crashes. `System.monotonic_time/0,1` is guaranteed non-decreasing within a VM lifetime, which is what duration measurement actually needs. (Correctness, Reliability)
- **Check:** Per-function: count `System.system_time` calls; verify the body contains arithmetic subtraction (`-`). Flag both conditions together.
- **Tolerate:** Two `system_time` calls for unrelated purposes (no subtraction); JWT or other cryptographic timestamp construction (which uses `+` and absolute wall-clock); documented case where wall-clock is required.
- **Severity:** `warning`

### 6.90 Loop-Invariant Constructor Inside `Enum`/`Stream` Lambda

An `Enum.*`/`Stream.*` lambda calls `Decimal.new`, `Date.from_iso8601!`, `DateTime.from_iso8601!`, `NaiveDateTime.from_iso8601!`, `Time.from_iso8601!`, or `Regex.compile!` with arguments that don't depend on the lambda's parameter.

- **Why:** These constructions allocate and parse on every iteration even when the result is constant. Hoisting the call above the lambda runs it once. With large datasets — and especially with `Decimal.new` — the savings are significant. (Performance)
- **Check:** Find `Enum`/`Stream` calls with a lambda. Walk the lambda body for parse-construction calls. Track the lambda's parameter names; flag any constructor whose arguments don't reference any parameter (loop-invariant).
- **Tolerate:** Loop-variant constructions (the argument depends on the lambda parameter); small fixed-size collections where the gain is negligible; documented per-iteration parsing.
- **Severity:** `info`

### 6.91 `Enum.into(coll, %{})` Should Be `Map.new(coll)`

`Enum.into(coll, %{})` or `Enum.into(coll, %{}, fun)` with the empty-map target.

- **Why:** `Map.new(coll)` (or `Map.new(coll, fun)`) is more direct, self-documents the intent, and skips the Collectable protocol dispatch. (Idiomatic Code, Performance)
- **Check:** Find `Enum.into` calls. Check the second argument for an empty-map literal `{:%{}, _, []}`. Handles both 2-arg (no transform) and 3-arg (with transform) forms.
- **Tolerate:** Explicit Collectable dispatch on a non-standard collectable; non-empty-map targets (legitimate use of `Enum.into`).
- **Severity:** `info`

### 6.92 `Ecto.Query.fragment` With String Interpolation (SQL Injection)

An `Ecto.Query.fragment` call whose first argument is a string with `#{...}` interpolation instead of `?` placeholders.

- **Why:** Interpolation embeds the value directly into the SQL string. The parameterized form `fragment("... ?", ^value)` sends the value as a bound parameter — the database driver escapes it. Interpolation is SQL injection. (Security)
- **Check:** Find `fragment/1,2,...` calls. Check the first argument's AST for an interpolated string `{:<<>>, _, parts}` containing non-binary parts (interpolation segments).
- **Tolerate:** Trusted compile-time literals (no `#{}` at all — pure string); column-name allow-list patterns where parameterization isn't possible AND the value is verified against a closed set; `^value` parameter binding (the correct form).
- **Severity:** `warning`

### 6.93 `Code.eval_*` in Production Code

`Code.eval_string`, `Code.eval_quoted`, or `Code.eval_file` called outside `lib/mix/tasks/` and tests.

- **Why:** `Code.eval_*` evaluates arbitrary Elixir at runtime. Even on "trusted" input, this is RCE — the default answer is no. Build-time tooling (Mix tasks, code generators) is the only legitimate home. (Security)
- **Check:** Find `Code.eval_string/eval_quoted/eval_file` calls. Skip test files and files under `lib/mix/tasks/` or `mix/tasks/`. Flag everything else.
- **Tolerate:** Mix tasks; test fixtures and code generators in `priv/`/`scripts/`; intentional REPL-like tools where the eval surface is itself the documented input boundary.
- **Severity:** `warning`

### 6.94 Hand-Rolled Crypto in Auth-Named Module

A module whose name segment includes `Auth`, `Token`, `Session`, `JWT`, `Otp`, `Verifier`, or `Signer` calls `:crypto.mac`, `:crypto.hmac`, or `:crypto.hash` directly.

- **Why:** Hand-rolled JWT, signed cookies, and password hashing have consumed engineering quarters chasing timing attacks, weak salts, and version skew. Vetted libraries (`Guardian`, `bcrypt_elixir`, `argon2_elixir`, `Plug.Crypto`) bake in the hard-won details. The default answer for security-sensitive primitives is "use a library." (Security)
- **Check:** Inspect module name; if any path segment matches an auth-related keyword, find every `:crypto.mac`/`:crypto.hmac`/`:crypto.hash` call in the module.
- **Tolerate:** Non-auth modules with incidental crypto; thin wrappers over a vetted library; test-only / demo crypto explicitly documented as such; documented case for a custom primitive (rare, requires security review).
- **Severity:** `warning`

### 6.95 Short-Circuit `with` for an Accumulating Validator

A function whose name suggests accumulating semantics (`validate_*`, `import_*`, `bulk_*`, `check_*`) uses a `with` chain with 2+ arrow steps that short-circuits on the first error.

- **Why:** `with` stops at the first failure (railway). An accumulating validator should collect ALL errors so the user can fix them in one round-trip. Short-circuit forces N fix/resubmit cycles, which is the wrong UX for forms, batch import, and multi-rule checks. (UX, API Design)
- **Check:** Filter functions by name prefix. Walk their bodies for `with` blocks; count arrow clauses. Flag when the function uses ≥2 bound variables in the success body and short-circuits. (See `elixir-implementing` §5.10.6 — accumulating reduce.)
- **Tolerate:** Sequential pipelines where later steps genuinely depend on prior results; intentional early-termination; functions whose names suggest accumulation but whose semantics are actually sequential.
- **Severity:** `info`

### 6.96 Verbose ok/error `case` Is `Result.map`

A `case` with two clauses: `{:ok, var} -> {:ok, transform(var)}` and `{:error, _} = err -> err`.

- **Why:** This is the canonical `Result.map` shape. The intent (transform success, pass error through) is buried under `case` ceremony. A `with`-chain (`with {:ok, v} <- f(), do: {:ok, transform(v)}`) or a project-local `Result.map/2` helper makes the shape explicit. (Idiomatic Code, Clarity)
- **Check:** AST walk for `case` expressions with exactly two clauses matching the ok/error pass-through shape (the error clause re-emits the matched value unchanged).
- **Tolerate:** Multi-clause error handling that maps different error reasons; case bodies that do more than transform on the success path; cases where explicit clarity outweighs the `Result.map` abstraction.
- **Severity:** `info`

### 6.97 Subject-Position Flip in Public Function

A 2-argument public function where the FIRST argument's name suggests options (`opts`, `options`, `config`) and the SECOND looks like the data subject (`data`, `list`, `map`, `coll`, `enumerable`, etc., or a struct destructure).

- **Why:** Idiomatic Elixir puts the data first (`Enum.map(coll, fn)`, `String.replace(s, p, r)`, `Map.put(map, k, v)`). Flipping breaks pipe composition and breaks reader expectations: `coll |> MyMod.do_thing(opts)` won't work if `opts` is the first arg. (Idiomatic Code, Pipeline Composition)
- **Check:** Per-2-arg public function: inspect arg names or destructure patterns. Flag when arg 1 matches options-naming and arg 2 matches subject-naming or struct destructure.
- **Tolerate:** Functions with intentional subject-last APIs documented as such; 3+ argument functions where the first-arg-data convention has the data later by design; functions where neither argument is clearly "the subject."
- **Severity:** `info`

### 6.98 Nested `Map.update` Should Use `update_in`

A `Map.update` / `Map.update!` whose update function contains another `Map.update` / `Map.put` on the same nested structure.

- **Why:** Two levels of nested update is the threshold where `update_in/2,3` and `put_in/2,3` are clearer: `update_in(state.counts.total, &(&1 + 1))` is more readable than nested `Map.update` lambdas. (Idiomatic Code, Readability)
- **Check:** Find outer `Map.update`/`Map.update!` calls. Walk the lambda body; flag when it contains an inner `Map.update`/`Map.put`/`Map.update!` on the lambda's parameter (or `&1`).
- **Tolerate:** Single-level updates; complex transformations where the nested form is genuinely clearer; dynamic paths where `update_in`'s static path doesn't fit.
- **Severity:** `info`

### 6.99 Eager `Enum` Chain Over Streamy Source

A `File.stream!`, `Repo.stream`, `IO.stream`, or `Stream.*` source piped through 3+ eager `Enum.*` steps.

- **Why:** Each eager `Enum` step materializes the full intermediate list. For a streamy source — file lines, DB cursor, large external API — that defeats the source's lazy contract and can OOM the node on big inputs. Use `Stream.*` for the intermediate steps and one `Enum.*` (or `Stream.run`) at the end. (Performance, Memory)
- **Check:** Unfold pipe chains. Identify the source (`File.stream!`, `IO.stream`, `Stream.*`, `Repo.stream`). Count subsequent eager `Enum.*` steps. Flag when the source is streamy AND eager-step count ≥ 3.
- **Tolerate:** Small fixed-size streamy sources where eager Enum is fine; pipelines whose final step is the only eager call (correct shape).
- **Severity:** `info`

### 6.100 List Recursion Is a Fold (Use `Enum.reduce`)

A private function with 2+ clauses matching `[]` and `[h | t]` that recurses with `t` and an accumulator.

- **Why:** This is the canonical fold pattern. `Enum.reduce/3` expresses it in one line, names what's happening, and removes the double-clause boilerplate. (Idiomatic Code, Conciseness)
- **Check:** Group private functions by `{name, arity}`. Detect (a) an empty-list clause returning `acc` (or `transform(acc)`) and (b) a cons-list clause recursing with the tail and a modified accumulator. Flag when both clauses are present.
- **Tolerate:** Non-fold recursion (tree traversal, mutual recursion); public recursive functions (API requirement); early-termination patterns better suited to `Enum.reduce_while/3`.
- **Severity:** `info`

### 6.101 Builder-Pattern Rebind Chain Should Be a Pipeline

Three or more consecutive rebindings of the same variable where each assignment is `var = call(var, ...)` (self-threading).

- **Why:** Pipelines thread the value implicitly, making the transformation chain visually clear. Rebind chains force the reader to verify line-by-line that each statement uses the binding from the previous line. (Readability, Idiomatic Code)
- **Check:** Walk statement blocks. Detect runs of `var = call(var, args)` patterns. Flag when run length ≥ 3.
- **Tolerate:** Interleaved computations between the rebinds (genuinely sequential, not a pipeline); guard clauses or error checks between steps.
- **Severity:** `info`

### 6.102 Encoder Without Decoder

A public `to_X/1` function in a module that also lacks a matching decoder (`from_X`/`parse_X`/`decode_X`).

- **Why:** Encoders without decoders create one-way data flows. The bidirectional pair lets you property-test `decode(encode(x)) == x` — a strong invariant that catches serialization bugs before they ship. (API Design, Testing)
- **Check:** Per-public-function: filter for `to_X/1` shape. Build the module's public function name set. Reject external-API patterns (`to_stripe`, `to_slack`), lossy projections (`to_integer`, `to_string`), stdlib wrappers, and one-line view-models. Flag remaining `to_X` without a matching `from_X`/`parse_X`/`decode_X`.
- **Tolerate:** External-service serializers (one-way by contract); lossy projections (no inverse exists); stdlib wrappers; internal view-models documented as one-way.
- **Severity:** `info`

### 6.103 Phantom-Type Opportunity

A module with `defstruct` defines both a smart constructor (`validate`/`parse`/`build`/`new`/`from_string`/`from_map`/`create`) returning `{:ok, %__MODULE__{}}` AND functions that consume `%__MODULE__{}` directly.

- **Why:** Splitting into two struct types — one unvalidated, one validated — makes the validation step observable in function signatures. Without the split, downstream code can't tell at the type level whether input has been validated; a missed `validate` call goes silent. (Type Safety, Design)
- **Check:** Detect `defstruct`. Detect smart constructors (name in a known set, body returns `{:ok, %__MODULE__{...}}`). Detect consumers (any clause arg destructures `%__MODULE__{}`). Flag when both are present.
- **Tolerate:** Value objects where validation isn't appropriate; types where unvalidated consumers are intentional (the module is a thin DTO); test fixtures.
- **Severity:** `info`

---

## 7. Test Architecture

### 7.1 Test Mirrors Source

Test file structure should mirror source structure (`lib/foo/bar.ex` → `test/foo/bar_test.exs`).

- **Why:** The mirroring convention makes test locations predictable: any developer can guess where to find tests for a module without searching. When source files lack mirrored tests, the missing files are invisible to coverage tools, hard to find for new contributors, and gradually the test suite stops covering whole sub-trees of the codebase. (Convention, Discoverability)
- **Check:** Project-level: compare lib/ structure with test/ structure. Flag source files without corresponding test files at the mirrored path.
- **Tolerate:** `application.ex`, `*_web.ex`, `endpoint.ex`, `router.ex`, `telemetry.ex`, `repo.ex`, `mailer.ex`, mix tasks.
- **Severity:** `info`

### 7.2 Repo in Tests

Tests should use context APIs, not direct Repo calls for setting up or asserting data.

- **Why:** Direct `Repo.insert` calls in tests couple tests to the database schema. When the schema changes, both the context and the tests break independently. Testing through the public context API means tests break only when the API contract changes — exactly when they should. (Test Coupling)
- **Check:** Flag `Repo.insert`, `Repo.update`, `Repo.delete`, `Repo.get` in test files.
- **Tolerate:** DataCase setup, test support/factory modules, seed data, cleanup operations.
- **Severity:** `info`

### 7.3 Mocks Need Behaviours

Every `Mox.defmock` must reference a behaviour module with `@callback` declarations.

- **Why:** Mox verifies that mocks implement the same callbacks as the behaviour — a compile-time guarantee that the mock's API matches the real implementation. Without a behaviour, the mock is unverified: you could mock a function that doesn't exist on the real module, and the test would pass while the production code crashes. (Contract Testing, Compile-Time Safety)
- **Check:** Flag `Mox.defmock` calls where the `for:` target module doesn't declare `@callback`.
- **Tolerate:** None — this is always a correctness issue.
- **Severity:** `warning`

### 7.4 Async Eligibility

Test files should declare `async: true` when eligible.

- **Why:** Async tests run in parallel, dramatically speeding up the test suite. Tests that don't modify global state can safely run async. Common blockers: named ETS tables, `Application.put_env`, named GenServers, Mox in global mode. All of these have async-safe alternatives. (Test Performance)
- **Check:** Flag test files without `async: true` that don't reference global state modifiers.
- **Tolerate:** Tests using `set_mox_global`, named ETS tables, `Application.put_env`.
- **Severity:** `info`

### 7.5 Sleep in Tests

`Process.sleep` in tests leads to flaky and slow tests.

- **Why:** Sleep-based tests are slow (always wait the full duration even when the operation completes in 1ms) and flaky (may not wait long enough under CI load). Use `assert_receive` with explicit timeouts for message-based assertions — it returns immediately when the message arrives and fails with a clear error after timeout. (Test Reliability, Test Performance)
- **Check:** Flag `Process.sleep` in test files.
- **Tolerate:** None — `assert_receive`, polling with `eventually`, or explicit synchronization is always better.
- **Severity:** `warning`

### 7.8 Test Naming

Test modules should be named `*Test` in `*_test.exs` files.

- **Why:** ExUnit discovers tests by filename convention (`*_test.exs`). A mismatched module name (module `MyApp.FooSpec` in `foo_test.exs`) causes confusion when running specific tests, and some tools assume the convention holds. (Convention)
- **Check:** Flag test modules where the module name doesn't match the `*Test` convention for the filename.
- **Tolerate:** Test support modules, shared test helpers.
- **Severity:** `warning`

### 7.9 No Assertion

Tests must contain at least one assertion.

- **Why:** A test without any assertion always passes — it tests nothing. It gives false confidence that the code works when it's actually never checked. Even compilation-only tests should use `assert` on the result. (Test Validity)
- **Check:** Flag test blocks without `assert`, `refute`, `assert_receive`, `assert_raise`, `assert_broadcast`, `assert_push`, or other assertion macros.
- **Tolerate:** Tests that verify side effects exclusively via Mox expectations (with `verify_on_exit!`).
- **Severity:** `warning`

### 7.10 Trivial Assertion

Tests with trivial assertions like `assert true`, `assert 1 == 1`, `assert :ok`.

- **Why:** Trivial assertions always pass regardless of what the code does — they're placeholders that were never replaced with real checks. They provide the illusion of test coverage without actually testing anything. (Test Validity)
- **Check:** Flag `assert true`, `assert 1 == 1`, `assert :ok`, `assert nil != nil`, and similar constant assertions.
- **Tolerate:** None — replace with meaningful assertions or delete the test.
- **Severity:** `warning`

### 7.11 Long Setup

Setup blocks with >400 AST nodes suggest over-coupled test infrastructure.

- **Why:** Large setup blocks create many implicit dependencies between tests. If setup changes, every test in the describe block may break. Each test should set up only what it needs — shared setup should be minimal (database connection, auth) and test-specific data should be created in the test itself or a focused helper. (Test Maintainability, Threshold calibrated against Logflare/Mydia)
- **Check:** Measure AST size of `setup` and `setup_all` blocks. Flag above 400 nodes.
- **Tolerate:** Integration test setups with complex multi-system initialization.
- **Severity:** `info`

### 7.12 Long Test

Test bodies with >1200 AST nodes likely test too many things at once.

- **Why:** A test that sets up data, performs multiple operations, and makes many assertions is testing a scenario, not a behaviour. When it fails, it's hard to identify which part broke. Split into focused tests — each tests one behaviour with one clear assertion. (Test Focus, Threshold calibrated against Logflare/Mydia)
- **Check:** Measure AST size of test bodies. Flag above 1200 nodes.
- **Tolerate:** Integration tests, end-to-end scenario tests.
- **Severity:** `info`

### 7.13 Mocks Not Verified

Mox setups must call `setup :verify_on_exit!` to enforce that expectations were met.

- **Why:** Without `verify_on_exit!`, Mox doesn't enforce that the expectations actually fired. A test that says `expect(MockClient, :fetch, fn _ -> :ok end)` and never reaches the call still passes — you've documented an interaction the code never made and the test gives false confidence. (Test Validity)
- **Check:** Flag test files that use `Mox.expect` or `Mox.stub` without `verify_on_exit!` in setup.
- **Tolerate:** None — always verify expectations.
- **Severity:** `warning`

### 7.14 Coverage Gap

Public API functions not referenced in the corresponding test file.

- **Why:** Public functions are the contract a module exposes — every one should have at least one test reference so regressions are caught. Low coverage on public API surfaces means changes can ship without anything noticing they broke a consumer's expected behaviour. (Test Coverage)
- **Check:** Project-level: for each source file, check if its public functions are called or referenced in the corresponding test file. Report coverage percentage and list uncovered functions.
- **Tolerate:** Framework callbacks (init, handle_call, handle_info), `@moduledoc false` modules, `application.ex`.
- **Severity:** `info`

### 7.15 Mocking Own Modules

Mock at system boundaries only — don't mock modules you own.

- **Why:** Mocks at system boundaries (HTTP, email, external APIs) shield tests from slow/flaky network. Mocking your own internal modules instead of using the real implementation tests the test, not the code: a refactor that breaks behaviour will leave the test green because the test is checking against a stub of the old behaviour. (Test Realism)
- **Check:** Flag `Mox.defmock` targets that appear to be internal modules (same app namespace, not in adapter/client/infrastructure/gateway/boundary path).
- **Tolerate:** Modules explicitly designed as boundary abstractions (adapters, clients, gateways).
- **Severity:** `info`

### 7.16 Runtime Config for DI

`Application.get_env` at runtime for dependency injection. Use `Application.compile_env` with module attributes.

- **Why:** Pulling the implementation from Application env on every call is slow (an Application lookup per call), not compile-time safe (a typo silently uses the default), and not friendly to Mox: tests have to set the env globally and remember to reset it. `Application.compile_env/3` reads the value once at compile time and pins it into a module attribute — faster, safer, and Dialyzer-visible. (Performance, Safety)
- **Check:** Flag `Application.get_env(:app, :key).function()` dispatch pattern — runtime DI via chained call.
- **Tolerate:** Config files, Application modules, values that genuinely vary at runtime.
- **Severity:** `info`

### 7.17 Generic Test Names

Test names should be descriptive — not "it works", "test 1", "happy path".

- **Why:** When a test fails, the name is the first (and sometimes only) thing you see in CI output. "it works" tells you nothing. "creates user with valid email and sends welcome notification" tells you exactly what broke and what the expected behaviour is. Good names serve as living documentation of the module's behaviour. (Test Readability, Documentation)
- **Check:** Flag test names matching generic patterns: "it works", "test N", "happy path", "should work", "basic test", "sanity check".
- **Tolerate:** None — rename to describe the specific behaviour being tested.
- **Severity:** `info`

### 7.18 Weak Assertion

`assert function()` without pattern match — only checks truthiness, not return shape.

- **Why:** `assert Accounts.create_user(attrs)` passes when the function returns `{:error, changeset}` because the tuple is truthy (not nil or false). The test says "creation succeeded" but it didn't — the assertion checked truthiness, not success. `assert {:ok, user} = Accounts.create_user(attrs)` catches the error shape immediately AND binds the result for further assertions. (Assertion Strength, False Positives)
- **Check:** Flag `assert function_call()` where the argument is a function call (remote or local) not wrapped in a pattern match (`=`), comparison (`==`, `!=`), or predicate.
- **Tolerate:** Predicate function calls (`assert Enum.any?(...)`, `assert Map.has_key?(...)`) — already return boolean by convention.
- **Severity:** `info`

### 7.19 Missing Test Cleanup

Test starts processes directly without `start_supervised!/1` or `on_exit/1` — causes test pollution.

- **Why:** Processes started with `GenServer.start_link` or `Task.start` in tests outlive the test case if not cleaned up. They may interfere with subsequent tests (holding database connections, occupying registered names, consuming port resources), cause test pollution, and make failures non-deterministic. `start_supervised!/1` auto-stops the process when the test ends. `on_exit/1` runs cleanup regardless of test pass/fail. (Test Isolation)
- **Check:** Flag test files that call `GenServer.start_link`, `GenServer.start`, or `Task.start` without `start_supervised!` or `on_exit` cleanup.
- **Tolerate:** Tests using `start_supervised!`, tests with explicit `on_exit` cleanup.
- **Severity:** `info`

### 7.20 Hardcoded Test Data

Test files containing real-looking email addresses (gmail.com, yahoo.com), Stripe API keys (sk_test_..., pk_test_...), or Bearer tokens.

- **Why:** Hardcoded real email addresses risk accidental side effects in integration tests (sending real emails). Hardcoded API keys risk leaking secrets to version control. Hardcoded production URLs risk hitting real APIs from CI. Use `@example.com` (RFC 2606 reserved), factories with generated values, or environment-based test credentials. (Safety, Test Hygiene)
- **Check:** Scan test file content for regex patterns matching real email providers, API key formats, and Bearer token patterns.
- **Tolerate:** `@example.com` addresses (RFC 2606), `localhost` URLs, obviously fake data.
- **Severity:** `info`

### 7.21 Test-Only Public Function *(compiled)*

Public function only called from test modules — never from production code.

- **Why:** A public function exercised only by tests suggests the test is reaching into implementation details rather than testing through the public API. Consider making the function `defp` and testing the behaviour through the module's public interface. (Test Architecture, Encapsulation)
- **Check:** Build compiled call graph. Find exported functions where all callers are test modules (modules ending in `Test`, `DataCase`, `ConnCase`, etc.). Exclude framework functions.
- **Tolerate:** Test helper functions intentionally public, functions called dynamically.
- **Severity:** `info`

### 7.22 Missing Error Path Tests

Test module with 5+ tests but no assertions exercising error paths.

- **Why:** Testing only the happy path leaves failure modes unverified. Error-producing functions have `{:error, _}` branches that need explicit testing — these are where production bugs hide. (Test Coverage, Error Handling)
- **Check:** Only analyze test files. Count total `test` blocks, count blocks containing `{:error` patterns in assertions. Flag when 5+ tests and 0 error-path assertions.
- **Tolerate:** Test modules for pure data-transformation code that genuinely has no error paths.
- **Severity:** `info`

### 7.23 Over-Mocking

Tests with 4+ `Mox.expect` calls or 3+ `Mox.stub` calls in a single test.

- **Why:** Many expectations in one test indicate the test is testing the mocking setup, not the actual behaviour. The test becomes fragile — any change to any mock breaks it. Consider testing through fewer, more meaningful boundaries. (Test Quality, Fragility)
- **Check:** Count `expect()` and `stub()` calls inside each `test` block.
- **Tolerate:** Integration tests that legitimately coordinate multiple external services.
- **Severity:** `info`

### 7.24 Empty Describe Block

`describe` block containing no `test` blocks.

- **Why:** An empty describe is dead scaffolding — visual noise that signals intended but unwritten tests. It's a blind spot in the test suite. (Test Coverage, Dead Code)
- **Check:** Find `describe` nodes, check if body contains any `test` nodes.
- **Tolerate:** Describe blocks with only `setup` (the setup is used by nested describes).
- **Severity:** `info`

### 7.25 Untested Module

Source module has no corresponding test file.

- **Why:** A module with no test file at all has zero automated verification. While some modules are legitimately untested (supervisors, application modules, generated code), most should have at least basic test coverage. (Test Coverage)
- **Check:** For each source file, compute expected test path (`lib/app/foo.ex` → `test/app/foo_test.exs`), check existence.
- **Tolerate:** `@moduledoc false` internal modules, config files, migrations, generated code, routers, endpoints.
- **Severity:** `info`

### 7.26 Process Leak in Tests

`GenServer.start_link` or `start_link` in test files without `start_supervised!`.

- **Why:** Processes started directly will leak if the test crashes. `start_supervised!` ensures the ExUnit supervisor stops the process after the test, preventing state pollution between tests. (Test Isolation)
- **Check:** Find `start_link` calls in test files that aren't wrapped in `start_supervised!`.
- **Tolerate:** Integration tests with explicit cleanup in `on_exit/1`.
- **Severity:** `info`

### 7.27 Assert on Implementation Detail

Tests use `:sys.get_state` or `Agent.get(pid, & &1)` to inspect internal process state.

- **Why:** Asserting on GenServer internal state couples the test to the implementation. If the state structure changes, the test breaks even though the behaviour is correct. Test observable behaviour through the public API instead. (Test Quality, Encapsulation)
- **Check:** Find `:sys.get_state` and `Agent.get(pid, & &1)` calls in test files.
- **Tolerate:** Debugging helpers, tests explicitly verifying internal state for infrastructure modules.
- **Severity:** `info`

### 7.28 Missing Boundary Tests

Context facade module has a test file but exercises fewer than 30% of its public API.

- **Why:** A context with 10 public functions but only 2-3 tested has significant coverage gaps at the boundary layer — the most important layer to test. (Test Coverage, Boundary Quality)
- **Check:** Project-level: for context facades (files with corresponding directories), count public functions and count function names appearing in the test file. Flag when < 30% coverage and 8+ public functions.
- **Tolerate:** Modules with fewer than 8 public functions. Modules tested through integration tests.
- **Severity:** `info`

### 7.29 Flaky Test Indicators

Test patterns that commonly cause intermittent failures.

- **Why:** `assert_receive` without explicit timeout uses 100ms default (too short for async work), `:rand.uniform`/`Enum.random` without seed creates non-deterministic tests, `DateTime.utc_now` in assertions creates timing-dependent tests. (Test Reliability)
- **Check:** Find `assert_receive` with 1 arg (no timeout), `:rand.uniform`/`Enum.random`, `DateTime.utc_now`/`System.monotonic_time` in test files.
- **Tolerate:** `assert_receive` with explicit timeout. Seeded random in property tests.
- **Severity:** `info`

### 7.30 `Mox.stub/3` In Test Body Should Be `expect/3`

A test body uses `Mox.stub/3` (not `stub_with`) when the file configures `verify_on_exit!`.

- **Why:** `stub` adds no expectation — it's a fallback that accepts being called zero or more times. `expect` records a MUST-happen assertion. When a test uses `verify_on_exit!` and stubs in the body, the natural intent is "this interaction happened" — that's `expect`'s job. `stub` belongs in shared `setup`. (Test Design)
- **Check:** Per-test-file: detect `verify_on_exit!` in setup or as a standalone call. Walk test bodies for `Mox.stub/3` (or bare `stub/3` when `Mox` is imported). Flag the calls.
- **Tolerate:** Tests that don't configure `verify_on_exit!`; stubs in `setup` blocks (correct location for fallbacks); tests where the same mock is also `expect`ed elsewhere in the body.
- **Severity:** `info`

### 7.31 Reach Into `changeset.errors` Should Be `errors_on/1`

Test code accesses `changeset.errors` directly via dot notation instead of using the Phoenix `errors_on/1` helper.

- **Why:** Raw `.errors` returns `[field: {message, opts}, ...]` — uninterpolated templates with internal options. The test ends up coupled to the raw representation. `errors_on/1` interpolates messages and returns `%{field => [messages]}`, decoupling the test from the changeset's internals and enabling cleaner pattern matches. (Test Resilience)
- **Check:** Per-test-file: AST walk for field-access `{{:., _, [{var, _, _}, :errors]}, _, []}` where `var` is a variable. Skips test files that don't have access to `errors_on/1`.
- **Tolerate:** Non-test code; references to `__MODULE__.errors`; manually-constructed error lists; tests that genuinely need raw template inspection.
- **Severity:** `info`

### 7.32 `assert {:ok/:error, ...} == call` Should Be Pattern Match

Test assertion uses `==` to compare a tagged-tuple literal against a function result instead of pattern-matching with `=`.

- **Why:** Pattern match (`=`) produces structural failure diffs and binds inner values for reuse downstream in the test (`assert {:ok, %User{id: id}} = ...; assert id > 0`). `==` produces flat line-based diffs that obscure which field is wrong, and you can't reuse the success value. Pattern matching also future-proofs against struct field additions. (Test Clarity)
- **Check:** AST walk for `assert` with `==` operator where the LHS is a tagged-tuple literal (`{:ok, _}`, `{:error, _}`, etc.). Skips non-test files.
- **Tolerate:** Comparisons of non-tuple values; non-tagged tuples; cases where exact equality (not pattern match) is the intended assertion.
- **Severity:** `info`

### 7.33 Multiple `stub/3` Calls For Same Mock Should Be `stub_with/2`

Three or more `stub/3` calls in the same test file targeting the same mock module.

- **Why:** Each `stub/3` is a maintenance seam — adding a new callback to the behaviour requires remembering to add a stub for it across every test that uses the mock. `Mox.stub_with(Mock, RealImplementation)` delegates all callbacks at once and picks up new ones automatically. (Maintainability)
- **Check:** Per-test-file: collect every `stub/3` (qualified or imported), group by mock module. Flag groups with ≥3 entries.
- **Tolerate:** Mocks with fewer than 3 stubs; tests already using `stub_with`; per-test `expect` overrides on top of a `stub_with` baseline.
- **Severity:** `info`

### 7.34 `timeout: :infinity` on a Test

`@tag timeout: :infinity` or `@moduletag timeout: :infinity` disables the per-test timeout entirely.

- **Why:** ExUnit's default 60 s timeout is the safety net that prevents a hung test from blocking CI indefinitely. `:infinity` removes the net — a deadlock, race, or slow dependency hangs the test runner until the CI worker is recycled, often invisibly. Every test should have a finite timeout sized to its workload. (Operational Reliability)
- **Check:** AST walk for `@tag` / `@moduletag` whose options include `timeout: :infinity`.
- **Tolerate:** Tests with explicit finite timeouts (`timeout: 60_000`); tests using the ExUnit default (no timeout tag at all); a documented case where infinity is genuinely required (extremely rare).
- **Severity:** `warning`

### 7.35 `assert_receive` / `refute_receive` Without Explicit Timeout

A bare `assert_receive pattern` or `refute_receive pattern` call relies on ExUnit's 100 ms default.

- **Why:** Async tests are a leading source of flakes. The 100 ms default is tuned for synchronous code where any longer wait would be a bug; async operations (Tasks, telemetry events, PubSub broadcasts) often need 500–2000 ms to absorb CI latency variance. An explicit timeout makes the wait budget visible and tunable. (Test Stability)
- **Check:** Per-test-file: AST walk for `assert_receive` and `refute_receive` calls with exactly one argument (the pattern).
- **Tolerate:** Calls with an explicit second-argument timeout (`assert_receive {:event, _}, 500`); strictly synchronous send-then-receive patterns.
- **Severity:** `info`

---

## 8. Event Sourcing Architecture

### 8.1 Command/Event Naming

Commands use imperative form (CreateAccount), events use past tense (AccountCreated).

- **Why:** Event sourcing relies on the naming convention to distinguish intent from fact: commands express an instruction to do something (imperative), events record that something happened (past tense). A past-tense command name reads like an event and obscures whether the module describes a request or a historical fact. This confusion cascades into handlers, projectors, and process managers. (Domain Language, CQRS Convention)
- **Check:** Flag command modules (under Commands namespace) ending in past-tense suffixes (-ed, -ied, -ten, -ade, etc.), and event modules (under Events namespace) starting with imperative prefixes (Create, Update, Delete, Send, etc.).
- **Tolerate:** Non-event-sourced modules, modules outside Commands/Events namespaces.
- **Severity:** `warning`

### 8.2 Pure Aggregate Apply

`apply/2` in aggregate modules must be pure — no side effects.

- **Why:** `apply/2` is invoked on every event during aggregate rehydration (process restart), not just when the event is first emitted. Side effects there fire N times per process restart: Logger calls spam observability tooling, HTTP calls re-trigger external systems, and email calls re-send notifications — all silently, on every aggregate load. The function must be a pure transformation: (state, event) → new state. (Event Sourcing Fundamentals, Replay Safety)
- **Check:** Flag calls to Logger, IO, GenServer, HTTP clients, external services, or `send/2` inside `apply/2` functions in modules that have both `execute/2` and `apply/2` (aggregate shape).
- **Tolerate:** Pure state transformations, calculations, struct updates.
- **Severity:** `error`

### 8.3 Immutable Events

Events must be immutable structs with `defstruct` and `@derive Jason.Encoder`.

- **Why:** Events are persisted facts that get serialized, replayed, and pattern-matched against. A plain module without a struct cannot be deserialized into a known shape, defeats compile-time field checks, and breaks every projector and process manager that pattern-matches the event. Mutating a stored event (`%{event | field: new_value}`) corrupts the audit trail. (Event Integrity, Serialization)
- **Check:** Flag event modules (under Events namespace) without `defstruct`, `defevent`, `typedstruct`, or `embedded_schema`. Also flag struct update syntax on events.
- **Tolerate:** Event macro usage (defstruct generated internally), upcaster modules (explicitly transform events on read).
- **Severity:** `error` / `warning`

### 8.4 Shared Projections

Projectors must not share read models — rebuilding one corrupts the other.

- **Why:** Each projector owns its read model so it can be rebuilt independently from the event stream. When two projectors write to the same schema/table, rebuilding one wipes or duplicates rows the other still needs, and the order in which they replay starts to matter. The coupling is invisible until you try to rebuild. (Projection Independence)
- **Check:** Graph-based: detect multiple projector modules referencing the same Ecto schema through edges in the module dependency graph.
- **Tolerate:** Reference data tables (countries, currencies) that are populated outside the event stream.
- **Severity:** `warning`

### 8.5 Events Need Jason.Encoder

Event structs must `@derive Jason.Encoder` for event store serialization.

- **Why:** Event stores serialize events to JSON before persisting. A struct without an encoder either raises at write time (`Protocol.UndefinedError`) or — worse — is silently encoded by a fallback that drops fields, producing events that cannot be replayed into the original shape. (Serialization, Data Integrity)
- **Check:** Flag event modules with `defstruct` but without `@derive Jason.Encoder`.
- **Tolerate:** Events using custom serialization, events with `@derive {Jason.Encoder, only: [...]}`.
- **Severity:** `warning`

### 8.6 Projector Reads External

Projectors must not call HTTP/external services or non-deterministic functions during projection.

- **Why:** Projectors are replayed against the event log to rebuild read models. An HTTP call talks to a remote service whose response can change, time out, or simply return different data than it did the first time. Non-deterministic calls (`DateTime.utc_now`, `:rand.uniform`) return different values on each replay. The rebuilt projection no longer matches the original — and the discrepancy is invisible until somebody compares. (Replay Determinism)
- **Check:** Flag calls to HTTP clients (HTTPoison, Finch, Req, Tesla), `DateTime.utc_now`, `:rand`, `System.system_time` inside `project/3` callbacks in modules using `Commanded.Projections.Ecto`.
- **Tolerate:** `Repo.get` (reading own projection table — common load-then-update pattern), event metadata timestamps.
- **Severity:** `warning`

### 8.7 Process Manager Reads Projection

Process manager state must come from events, not from Repo reads on projections.

- **Why:** Process managers must derive their state from the events they have observed, via `apply/2`. Reading from a projection (via `Repo.get`, `Repo.all`) means decisions depend on a read model that may not yet have caught up — leading to race conditions during replay and after restarts, plus invisible coupling to the projector's lifecycle. (Event Sourcing Consistency)
- **Check:** Flag `Repo.get`, `Repo.get!`, `Repo.get_by`, `Repo.one`, `Repo.all` calls inside process manager modules (using `Commanded.ProcessManagers.ProcessManager`).
- **Tolerate:** None in event-handling callbacks.
- **Severity:** `warning`

### 8.8 Aggregate Missing Behaviour

Modules with `execute/2` and `apply/2` but no `use Commanded.Aggregates.Aggregate`.

- **Why:** A module that walks like an aggregate (command handler + event applier) but doesn't declare itself as one is invisible to the framework: no GenServer wrapper, no snapshotting, no router registration, and the compiler can't check the callback shapes against the behaviour. It may work coincidentally but break when the framework evolves. (Framework Integration)
- **Check:** Flag modules that define both `execute/2` and `apply/2` as public functions without `use Commanded.Aggregates.Aggregate`.
- **Tolerate:** Non-Commanded projects, policy/service modules that happen to use these function names for unrelated purposes.
- **Severity:** `info`

### 8.9 Event / Command Struct Missing `:version`

A struct in an `Events` or `Commands` namespace has no `:version`, `:schema_version`, or `:event_version` field (or matching module attribute).

- **Why:** Event-sourced systems must replay older instances after schema evolution. Without a version marker, upcasters cannot dispatch on "which version is this?" — adding a field becomes a breaking change against persisted events. Commands in versioned APIs face the same problem. Picking an evolution strategy (inline version field OR `defimpl Commanded.Event.Upcaster`) at design time prevents whole classes of replay bugs. (Event Sourcing, Schema Evolution)
- **Check:** Walk `defmodule` nodes; classify by namespace presence of `Event(s)` or `Command(s)` in the module path. For each, verify the `defstruct` has a version-family field OR the module has `@version` / `@schema_version` / `@event_version`.
- **Tolerate:** Modules outside event/command namespaces; events whose version is encoded via separate type modules (`V1.OrderPlaced`, `V2.OrderPlaced`); upcaster-based versioning where the strategy is documented.
- **Severity:** `warning`

---

## 9. State Machine Architecture

### 9.1 State Reachability

All defined states must be reachable from initial states via transitions.

- **Why:** An unreachable state is dead code — it was defined but no transition path leads to it. It confuses readers, may indicate a missing transition (a bug), and adds maintenance cost for code that can never execute. (Completeness, Dead Code)
- **Check:** Build a directed graph from transition definitions. BFS/DFS from all initial states. Flag states with no path from any initial state.
- **Tolerate:** States explicitly documented as "reserved for future use."
- **Severity:** `warning`

### 9.2 Terminal State Integrity

States named like terminal states (completed, cancelled, failed) should have no outgoing transitions except self-loops.

- **Why:** States named `completed`, `cancelled`, `failed`, `terminated`, `done`, `closed`, `archived`, `deleted`, `expired` are conventionally terminal — once entered, they shouldn't transition out. A terminal state with outgoing edges either means the state isn't really terminal (misleading name) or the transitions are bugs that let entities resurrect from a final state. Either way, the state diagram is inconsistent with itself. (State Machine Consistency)
- **Check:** Flag states with terminal-sounding names that have transitions to non-self states.
- **Tolerate:** Self-loops (e.g., `completed → completed` for idempotent retries).
- **Severity:** `warning`

### 9.3 Implicit Boolean State

Schemas with 3+ state-suggesting boolean fields (is_active, is_verified, is_suspended) — use a single status enum.

- **Why:** When an entity has 3+ booleans like `is_active`, `is_verified`, `is_suspended`, the schema implicitly defines a 2^n state machine where most combinations are invalid (e.g., `active=true, suspended=true`). The valid states aren't documented, the invalid ones can be created by mistake, and reasoning about transitions becomes detective work. A single `:status` enum field makes states explicit and invalid combinations unrepresentable. (State Representation, Data Integrity)
- **Check:** Count boolean fields with state-suggesting names (`is_*`, `has_*`, `was_*`, `*_active`, `*_enabled`, `*_verified`, `*_completed`, `*_confirmed`, etc.) in Ecto schema modules. Flag schemas with 3+ such fields.
- **Tolerate:** Independently meaningful booleans (`can_email`, `can_sms`, `can_push` — capabilities, not states) where every combination is valid.
- **Severity:** `info`

### SM-A Transition Target State Not in `@states`

A `{:next_state, target, ...}` transition where `target` isn't in the module's declared `@states` set.

- **Why:** An undeclared `:next_state` target is a guaranteed runtime crash — the state machine will receive an event it has no callback for. Pattern-matching makes this invisible at compile time in `handle_event_function` mode and in hand-rolled machines. Declaring states up front and verifying transitions stay inside that set catches the bug at lint time. (Correctness, State Machines)
- **Check:** Per-module: extract `@states [:a, :b, :c, ...]`. Walk the AST for `{:next_state, target, ...}` returns. Flag when `target` is a literal atom not in `@states`.
- **Tolerate:** Modules without an `@states` declaration (the rule has no anchor); transitions whose target is computed at runtime (variable rather than literal); documented case where the target is intentionally outside the declared set.
- **Severity:** `warning`

### SM-D State Assignment Outside Declared `@states`

An assignment `state: <literal-atom>` where the atom isn't in the module's `@states` set.

- **Why:** Assigns a state value the rest of the module doesn't know how to handle, leading to `FunctionClauseError` or silent misbehaviour the next time the state is dispatched on. The check forces the state vocabulary to remain a closed set documented in one place. (Correctness, State Machines)
- **Check:** Per-module: extract `@states`. Walk `state: value` keyword assignments and `%{state: value}` map updates; flag when `value` is a literal atom not in `@states`.
- **Tolerate:** Modules without `@states`; computed (non-literal) state values; intentional out-of-set values documented inline.
- **Severity:** `warning`

### SM-F Incomplete State Match — Declared States Not Handled

A `case` (or function-head pattern set) on the state value that omits states declared in `@states` and lacks a catch-all clause.

- **Why:** The state declaration says these states exist; the consumer needs to handle each one or explicitly fall through with `_`. A missing state crashes with `CaseClauseError` the next time the state is set legitimately and reaches this consumer. (Correctness, State Machines)
- **Check:** Per-module: extract `@states`. Find `case state` (and similar) sites; collect the literal-atom clauses; flag when declared states are missing AND no catch-all clause exists.
- **Tolerate:** Catch-all `_` clause covering remaining states; intentional partial handling documented inline (rare); modules without `@states`.
- **Severity:** `warning`

---

## 10. Composition and Extensibility

### 10.1 Shallow Use

Prefer composition over deep `use` chains. More than 2 non-standard `use` statements per module.

- **Why:** Deep `use` chains are the functional equivalent of multiple inheritance. Each `use` injects functions, attributes, and `__using__` macros into the module's scope, but the reader can't see what was added without reading every `__using__` body. The implicit coupling makes refactors fragile and overrides surprising — you don't know what you're overriding because you don't know what was injected. (Explicitness, Readability)
- **Check:** Count non-standard `use` statements per module (excluding GenServer, Agent, Supervisor, DynamicSupervisor, Task, ExUnit.Case, ExUnit.CaseTemplate, Phoenix.Controller, Phoenix.LiveView, Phoenix.LiveComponent, Phoenix.Component, Phoenix.Channel, Ecto.Schema, Ecto.Migration, Plug.Builder, Plug.Router, Application). Flag above 2.
- **Tolerate:** Test files (often use multiple test case templates).
- **Severity:** `info`

### 10.2 Namespace Depth

Module nesting should not exceed the configured maximum depth.

- **Why:** `MyApp.Foo.Bar.Baz.Qux.Internal.Helper` is 7 levels deep — each level adds organizational overhead without adding clarity. Deep nesting usually indicates over-decomposition or a directory structure mimicking Java packages. Elixir's flat module namespace works best with 3-4 levels: `MyApp.Context.SubModule`. (Readability, Convention)
- **Check:** Count dots in the module name. Flag above the configured threshold.
- **Tolerate:** Generated modules, umbrella app prefixes (which add one level).
- **Severity:** `info`

### 10.3 Pipeline Order Flip

A function whose `@spec` input types are a permutation (but not equal) of the return tuple's element types — `(T1, T2) → {T2, T1}` for arity 2, and the analogous permutation for higher arities.

- **Why:** Pipelines compose by feeding one function's output into the next function's first argument. When a function takes `(T1, T2)` and returns `{T2, T1}`, the result cannot be piped into anything expecting `T1` first — including another instance of itself. The order flip prevents the most basic form of composition without a domain reason. (Composability)
- **Check:** Per-function spec walk: extract the input type list and the return tuple (`{a, b}` or `{:{}, _, [...]}`); fire when the multisets are equal but the orders differ. Pure structural detection, no name heuristics.
- **Tolerate:** The swap IS the function's purpose (e.g., `swap/2`) — moduledoc note or `@archdo_arg_order_ok` marker.
- **Severity:** `info`

### 10.4 Pipeline Side-Effect Terminator

A function with a typed first parameter `T` that performs a known side effect (`Logger`, `:telemetry.execute`, `Phoenix.PubSub.broadcast`, `Repo` writes, `File`/`IO`) and returns a value that is neither `T` nor `{:ok, T}`.

- **Why:** Pipelines compose by feeding one function's output into the next function's first argument. A side-effect function that takes `T`, performs an observability effect, and returns `:ok` / `nil` / an unrelated atom forces callers to break the pipeline (assign, call for effect, continue with the original value). Returning `T` (or `{:ok, T}`) keeps the chain intact. (Composability)
- **Check:** Per-function spec walk + body inspection. Skip when the first parameter is `any()` / `term()` (no concrete type to compare against). Skip when the return is `T`, `{:ok, T}`, or any union member is `T` / `{:ok, T}`. Otherwise, scan the body for a known side-effect call; fire if found.
- **Tolerate:** The function's contract IS to return a different shape (e.g., an audit record); the side effect is the function's primary purpose.
- **Severity:** `info`

### 10.5 Pipeline Shape Mismatch

A producer function `g/n` returns a tuple of types `{T1, T2, ..., Tk}`; a consumer function `f/k` accepts the same multiset of types but in a different order. The pipeline `g(...) |> f(...)` cannot be expressed without manual re-shuffling.

- **Why:** Cross-module pipeline composition requires that one function's output shape matches the next function's input shape. When the type multisets agree but the orders differ, the pipeline has to be written `f(elem(g(), 1), elem(g(), 0))` or via destructuring — losing the composition benefit. The fix is to reorder either the producer's return tuple or the consumer's parameter list; the rule reports the mismatch and leaves the resolution to the developer. (Composability, Structural Coupling)
- **Check:** Project-level analysis. Index every spec's return tuple shape (producers) and every spec's input tuple shape with arity ≥ 2 (consumers). Fire on every (producer, consumer) pair where the type multisets match but the orders differ. Skip self-pairs.
- **Tolerate:** The producer and consumer are intentionally independent; both orders have multiple call sites and reordering either would break callers — accept the mismatch and document the decision.
- **Severity:** `info`

### 10.6 Ordered Middleware Chain Constraints

A `pipeline :name do plug ... end` block (Phoenix router) — or any chain of the same shape — violates one of three structural constraints: (a) the same plug is declared twice in one pipeline; (b) an authorization plug runs before its authentication counterpart; (c) a browser-shaped pipeline is missing CSRF protection.

- **Why:** Middleware chains encode security and observability invariants by ordering and presence. Auth must run before authz; parsers must run before session; browser pipelines that accept session cookies must include CSRF protection. A duplicate entry usually indicates a refactor leftover that runs the plug twice with the second instance's config silently overwriting the first. (Security, Composition Discipline)
- **Check:** Walk every `pipeline :name do ... end` block; collect the ordered list of `plug` entries. Apply: duplicate-key check; auth-before-authz ordering (against a configurable list of auth/authz plug names); `Plug.Parsers`-before-`:fetch_session` ordering; presence of `:protect_from_forgery` in any `:browser`-named pipeline or any pipeline that includes browser-signal plugs (`:put_root_layout`, `:put_secure_browser_headers`, `:fetch_live_flash`).
- **Tolerate:** A pipeline whose name happens to be `:browser` but serves only public, non-mutating routes (rare); duplicate plug intentional with two different configs (very rare). Pipeline-specific exemption via `# archdo:allow 10.6` on the pipeline line.
- **Severity:** `warning`

### Building-Block Composability (verdict mechanism)

Beyond the rules above, Archdo measures composability per public function across six axes — input closure, determinism, output completeness, totality, side-effect freedom, and errors-as-values. Each function gets a building-block score; modules and contexts roll up to a verdict (`:building_block`, `:leak`, or `:no_public_api`) so an entire context is a building block only when every module under its namespace is.

- **Why:** A function that meets all six axes — finite specified inputs, known input-to-output relation, no hidden state or side channels — is a **building block**: code we own and understand from the inside that nonetheless composes as cleanly as if it were opaque. (Externally-supplied code with the same properties would be a true *black box* — code we cannot see inside. In our own code we should never have black boxes; we have building blocks instead.) The score is form, not substance: it tells you what you've earned the right to do (memoize, parallelize, distribute, property-test) without telling you whether the function is correct. (Composability, Substitutability)
- **Check:** Per-public-function score across the six axes; per-module mean; per-context aggregation. Surface via `mix archdo --building-blocks` and `mix archdo --metrics`. Drives CE-54, CE-55, CE-56, and CE-57 directly (those rules act on the score but classify the diagnostic as a Change Economy concern: low-possibility-high-value, untested, effect-leaked, unguarded).
- **Tolerate:** Boundary modules and adapters legitimately score low — that is expected at I/O seams. The diagnostic value is in stable-classified modules whose score is below threshold (CE-54), not in low scores per se.
- **Severity:** Verdict only — see CE-54 / CE-55 / CE-56 / CE-57 for the rules that act on it.

---

## 11. Native Interop (NIFs, Ports, Rustler)

### 11.1 NIF Behind Behaviour

NIF modules should implement a behaviour for replaceability and testing.

- **Why:** NIFs are native code that lives outside the BEAM's safety net: a crash takes the whole VM down. Hiding the NIF behind a behaviour gives you a clean abstraction: tests can swap in a pure Elixir implementation, the public surface is documented via `@callback`, and consumers depend on the behaviour rather than the unsafe native module directly. (Testability, Safety, Abstraction)
- **Check:** Flag modules with `use Rustler`, `use Zig`, `@on_load`, or `:erlang.nif_error` that don't declare or implement a `@behaviour`.
- **Tolerate:** None — all NIFs should have a behaviour boundary.
- **Severity:** `warning`

### 11.2 NIF Scheduler Safety

NIFs processing variable-size input should use dirty schedulers to avoid blocking the BEAM.

- **Why:** Regular NIFs run on the BEAM's normal schedulers. Anything that takes more than ~1ms blocks the scheduler and prevents thousands of other processes from making progress. Operations on user-supplied binaries or lists can vary wildly in size, and a slow run starves the entire VM. Dirty schedulers give the BEAM dedicated threads for these operations. (BEAM Safety, Latency)
- **Check:** Flag NIF modules with stub functions (`raise "NIF not loaded"` or `:erlang.nif_error`) but no dirty scheduler configuration (`DirtyCpu`, `DirtyIo`, `dirty: :cpu`).
- **Tolerate:** NIFs proven to complete in <1ms, fixed-size operations.
- **Severity:** `warning`

### 11.3 NIF Panic Patterns

Rust NIF code must not contain `unwrap()`, `expect()`, `panic!()`, or `todo!()` — these crash the entire VM.

- **Why:** NIF Rust code runs in the same OS process as the BEAM. Any Rust panic propagates as a process abort, killing the entire VM along with every process, connection, and in-flight request it serves. The same code in non-NIF Rust would just unwind the thread; in a NIF it's a global outage. Replace with `?` operator and Result-returning functions that convert errors to Elixir `{:error, reason}` tuples. (VM Safety, Availability)
- **Check:** Scan `.rs` files in `native/` directories for `unwrap()`, `.expect(`, `panic!(`, `todo!(`, `unimplemented!(`. Skip `#[cfg(test)]` blocks (test code is fine) and comment lines.
- **Tolerate:** Test modules, static initialization that cannot fail.
- **Severity:** `warning`

### 11.4 Port vs NIF Decision

Choose Port when safety matters more than NIF latency. Ports run in a separate OS process.

- **Why:** Ports run in a separate OS process — crashes don't take down the BEAM and there's no scheduler concern at all. They cost more per call than NIFs (inter-process communication overhead) but eliminate the safety class entirely: a bug in a Port crashes the Port, not the VM. NIFs should only be used when the latency difference (microseconds vs milliseconds) is critical for the use case. (Safety vs Performance Tradeoff)
- **Check:** Flag NIF modules that primarily do I/O (file, network, database) rather than tight computation — Ports would be safer for I/O-bound work.
- **Tolerate:** Computation-heavy NIFs (crypto, image processing, parsing), latency-critical hot paths.
- **Severity:** `info`

---

## 12. Change Economy

The Change Economy pack measures the *cost of changing* the system, not its current shape. Where most rules ask "is this code well-structured today?", these ask "will the next requirement land cheaply, or will it require ripple changes across the codebase?". The pack splits **Substitutability** (the ability to swap an implementation, paid for via behaviours/protocols/adapters) from **Changeability** (the ability to modify code as requirements evolve, achieved through simplicity). Substitutability is wanted at volatile boundaries; Changeability is wanted everywhere — and the two have very different cost/benefit profiles.

Volatility classification underlies most of these rules: a module that touches I/O, external services, or non-determinism is presumed volatile; a pure-domain module is presumed stable. Authors override with `@archdo_volatility :stable | :volatile | :mixed | :entry_point`; paths can be marked in `.archdo.exs`.

### CE-1 Volatile module with hardcoded dependencies

Volatile modules calling another volatile primitive directly, with no behaviour seam, no Mox port, and no injected dependency.

- **Why:** Substitutability is the only mechanism that buys a test seam and vendor-drift insulation at a volatile boundary, and it's missing. Tests cannot exercise the module without real I/O; the dependency cannot be swapped. (Substitutability)
- **Check:** For each volatile module, follow outgoing volatile calls and verify each is mediated by `@behaviour`-bound dispatch with a Mox mock, function-parameter injection, or `Application.get_env`-bound module slot.
- **Tolerate:** Module marked `@archdo_volatility :stable` or `:entry_point`; entry-point modules (`use Mix.Task` / `use Application`) auto-exempt.
- **Severity:** `warning`

### CE-2 Volatile boundary lacks abstraction layer

A volatile module is exposed to ≥ 2 non-volatile callers without any behaviour/protocol/configurable-adapter layer between them.

- **Why:** When the external dependency changes (API version, vendor swap, deprecation), every caller is affected. The abstraction is the insulation that absorbs external change without ripple. (Substitutability, Insulation)
- **Check:** For each volatile module with ≥ 2 distinct non-volatile callers, verify at least one caller reaches it through a behaviour, protocol, or configurable-adapter slot.
- **Tolerate:** Single-caller helpers; framework-provided abstractions with their own test seam (Ecto.Repo, Phoenix.PubSub, Oban, OTP primitives).
- **Severity:** `warning`

### CE-3 Stable core with abstraction density above codebase median

A stable module contains behaviours, protocols, configurable adapters, or injection points at higher density than the codebase median.

- **Why:** Substitutability is being paid for in the part of the system that doesn't need it. Pure stable code already has full Changeability through simplicity alone; behaviours here add concepts the reader must navigate without buying a test seam or insulation. (Simplicity)
- **Check:** Per-module `abstraction_density = (behaviours + protocols + configurable_slots + injected_deps) / public_function_count`; flag stable modules above 2× codebase median.
- **Tolerate:** Module *defines* a behaviour or protocol (`@callback`, `defprotocol`); module is a documented public extension surface (`@archdo_extension_point true`).
- **Severity:** `warning`

### CE-4 Mixed-volatility module (split candidate)

A module classified as mixed — neither a clean I/O boundary nor a clean domain core.

- **Why:** Mixed modules sit between regimes and get neither benefit. Pure parts pay a Substitutability cost they wouldn't need; volatile parts can't get a clean test seam. Every change to the I/O parts forces re-testing the domain parts and vice versa. (Cohesion)
- **Check:** Volatility classifier returns `:mixed` (volatile-call density between 0.05 and 0.40).
- **Tolerate:** Small adapter modules where I/O density is structurally near 50% (e.g., a CSV importer); marker `@archdo_split_unjustified`.
- **Severity:** `warning`

### CE-11 Irreversible-decision module lacks contract density

Modules representing hard-to-reverse decisions — Ecto schemas, supervision-tree shape, public APIs — without specs, tests, and documentation at adequate density.

- **Why:** Irreversible decisions have asymmetric cost: getting them wrong is expensive to roll back. Specs + tests + docs are the cheapest insurance against drift, and they amortize across every consumer. (Risk-Weighted Investment)
- **Check:** Identify schemas, supervisors, and modules in `package.exports` / `public_api_paths`; compare `@spec` coverage, test density, and `@moduledoc` + `@doc` coverage against codebase median.
- **Tolerate:** Module marked with a deadline-bearing `@archdo_specs_pending` or equivalent.
- **Severity:** `warning`

### CE-12 Public-API module with low @spec coverage

A module designated public API where fewer than 80% of public functions have `@spec`s.

- **Why:** Public APIs without specs cannot be Dialyzer-verified, callers must read source to understand contracts, and breaking changes are silent at compile time. (Contract Stability)
- **Check:** For each public-API module (Ecto schemas, Supervisor implementors, paths in `public_api_paths`), compute `spec_coverage` and fire below 0.80.
- **Tolerate:** Module marked `@archdo_specs_pending` with a deadline.
- **Severity:** `warning`

### CE-15 Wrapper layer over framework-provided abstraction

A project-defined behaviour with ≤ 1 production implementation that wraps a framework primitive (Ecto.Repo, Phoenix.PubSub, Oban, OTP) which already provides a working test seam.

- **Why:** Double abstraction. The framework already provides Substitutability — Sandbox for Ecto, testing helpers for PubSub/Oban. The wrapper pays a layer cost for capabilities that already exist and typically fails to expose framework features cleanly, forcing leaky-abstraction escape hatches. (Avoid Double Abstraction)
- **Check:** For each behaviour with ≤ 1 non-test implementor, identify the principal call target inside the impl; if it's a known framework abstraction with a documented test seam, flag the behaviour.
- **Tolerate:** Wrapper enforces a *policy* the framework doesn't (tenant scoping, audit logging) — `@archdo_policy_wrapper`; wrapper exposes a domain-shaped interface and the framework is genuinely a hidden detail.
- **Severity:** `warning`

### CE-17 Connascence of meaning across modules

The same magic value (number, string, atom) compared or assigned in ≥ 2 modules without a shared symbolic constant.

- **Why:** Every consumer must know the magic value's meaning out-of-band. Renaming or renumbering forces search-and-replace across modules; missing a site is a silent bug. Connascence of meaning across modules is one of the strongest forms of coupling at the longest distance. (Connascence)
- **Check:** Walk all modules; collect literals appearing in comparisons or status-shaped assignments; group by value; flag values appearing in ≥ 2 modules without a shared module-attribute, behaviour-defined, or `defenum`-style accessor.
- **Tolerate:** Stable numeric constants (`0`, `1`, `-1`, status code `200`, port `80`/`443`); incidental local literals.
- **Severity:** `warning`

### CE-21 Acquire/release pair without bracket helper

A module exposes paired public functions (`open`/`close`, `acquire`/`release`, `subscribe`/`unsubscribe`, `lock`/`unlock`) without a `with_X/2` bracket helper that pairs them.

- **Why:** Every caller must remember to pair the calls and handle the cleanup branch on exception. Forgotten releases leak resources; orphaned locks deadlock. The pair is connascence of execution between two distant call sites. (Connascence of Execution)
- **Check:** Match public function pairs by name; verify the same module exposes a bracket function whose body invokes the pair around a callback or `try/after`.
- **Tolerate:** Pairs exposed for genuinely long-lived resources spanning multiple processes (`GenServer.start_link` + `GenServer.stop` for app-lifetime processes).
- **Severity:** `info`

### CE-23 High cognitive complexity public function

A public function whose Campbell-style cognitive complexity exceeds threshold (default `> 15` warning, `> 25` error).

- **Why:** Cognitive complexity tracks human reading difficulty, not graph paths. It does not penalize flat dispatch but penalizes nested control flow. The function is hard to read, hard to modify safely, and hard to test exhaustively — a Changeability and testability impediment. (Cognitive Load)
- **Check:** AST walk per Campbell's rules: `+1` per control-flow structure, `+nesting_depth` per nested structure, `+1` per chained logical operator beyond the first, `+1` per recursion edge; multi-clause functions count as one `case` unless clauses contain nested logic.
- **Tolerate:** Function marked `@archdo_complex_ok`; generated code (parsers, state-machine tables, schema-derived).
- **Severity:** `warning` above 15, `error` above 25 (in strict mode)

### CE-24 Cyclomatic / cognitive complexity shape mismatch

Functions where cyclomatic and cognitive complexity disagree by more than 2× in either direction.

- **Why:** The disagreement carries information neither metric alone provides: twisty-nested (cognitive ≫ cyclomatic) is the genuine refactor target pure cyclomatic linting misses; flat-dispatch (cyclomatic ≫ cognitive) is idiomatic Elixir over-counted by cyclomatic. (Calibrated Complexity)
- **Check:** Compute both per function; classify as `flat-dispatch` (informational, auto-suppress cyclomatic complaints), `twisty-nested` (warning, often pairs with CE-23), `uniform-complex`, or `simple`.
- **Tolerate:** Flat-dispatch shape is acknowledged at informational severity, not as a refactor recommendation.
- **Severity:** `warning` (twisty-nested) / `info` (flat-dispatch)

### CE-25 Cross-cutting concern density per function

Functions where calls to known cross-cutting modules (Logger, telemetry, transactions, retry, authorization, audit) make up more than 40% of body expressions.

- **Why:** Domain intent is buried under aspect noise. Adding a new aspect (rate limiting, idempotency tokens) requires editing every such function; removing one requires the same. The function reads as "do these cross-cutting things, and somewhere in the middle do the actual work." (Aspect Containment)
- **Check:** Configure cross-cutting modules per `.archdo.exs`; for each function with ≥ 5 expressions, compute `density = cross_cutting_calls / total_expressions`; flag above 0.40.
- **Tolerate:** Function is itself the bracket / pipeline aggregator (`@archdo_aspect_aggregator true`); function is at a documented composition layer (Plug, LiveView event handler).
- **Severity:** `warning`

### CE-26 Scattered cross-cutting concern

Cross-cutting call sites where the call shape (event name, log key, telemetry path, audit category) varies as synonyms across the codebase.

- **Why:** Consumers downstream — log aggregators, telemetry dashboards, audit pipelines, alerting rules — must know about every variant. Adding a new variant breaks dashboards silently; renaming requires coordinated change across producer code, dashboards, and alerts. (Taxonomy Stability)
- **Check:** Collect call sites per cross-cutting module; group by first argument; cluster by string/list similarity; flag clusters of ≥ 3 high-similarity names.
- **Tolerate:** Variants signed off by the dashboard/log-aggregator owner; variant required by an external schema.
- **Severity:** `warning`

### CE-27 Architectural boundary without telemetry span

Phoenix controller actions, public-API entry points, `Mix.Task.run/1`, `Oban.Worker.perform/1`, and channel handlers lacking a `:telemetry.span` (or framework equivalent).

- **Why:** The boundary is invisible to operations. Latency, error rates, and throughput cannot be measured; alerting cannot be wired up; SLO tracking is impossible. (Observability)
- **Check:** Identify boundary entry points via the anchor set; scan the body and up to two call levels for `:telemetry.span`, `:telemetry.execute`, or framework-provided equivalents listed in `.archdo.exs` `telemetry_emitters`.
- **Tolerate:** Module / function marked `@archdo_no_telemetry`; observability centralized at a higher layer (e.g., a Plug emitting telemetry for all routed requests).
- **Severity:** `info`

### CE-28 Error path without log

Functions returning `{:error, _}` literals or containing `rescue` blocks without an in-scope `Logger` call.

- **Why:** Errors disappear silently; debugging requires reproducing the path; alerting cannot fire on patterns the logs don't expose. (Observability)
- **Check:** AST scan for `{:error, _}` literal returns and `rescue` clauses; walk up the static call graph two levels checking for `Logger.error`/`Logger.warning` referencing the error.
- **Tolerate:** Error is normal control-flow tuple expected by the caller (`Repo.fetch` returning `{:error, :not_found}` as a domain answer); function tagged `@archdo_silent_error`.
- **Severity:** `info`

### CE-29 Process state without inspection hook

Long-running stateful processes (`use GenServer`, `use Agent`, `:gen_statem` callback modules) without `format_status/1` or a documented inspection-friendly state shape.

- **Why:** Debugging requires tracing or restarts; runbooks become guess-and-check; production support has no live introspection. For PII-bearing state, lacking an Inspect filter risks leaking via Observer or `:sys.get_state`. (Operability)
- **Check:** Identify modules using long-running stateful behaviours; check for `format_status/1` or a documented state-shape attribute; for state structs with PII-pattern fields, also verify `@derive {Inspect, except: [...]}`.
- **Tolerate:** State genuinely contains operational secrets requiring elevated access; marker `@archdo_opaque_state`.
- **Severity:** `warning`

### CE-30 Unanchored module or public function

A module or specific public function not transitively reachable from any anchor.

- **Why:** The code adds maintenance load, search-result noise, refactor friction, and dependency surface without contributing to any externally-visible behaviour. This is the most common form of "unjustified code" in LLM-generated and exploratory codebases. (Justification)
- **Check:** Build the call + import/use graph; compute the closure of the anchor set (Phoenix routes, supervised processes, Mix tasks, Oban workers, `package.exports`, `additional_anchors`); flag anything outside the closure. Test-only-anchored modules are reported separately.
- **Tolerate:** Module marked `@archdo_anchor` with a stated rationale (e.g., "called via :erpc from sibling node"); known plugin/extension hook (`@archdo_extension_point true`); generated code.
- **Severity:** `info`

### CE-31 Unanchored island (mutually-reachable cluster)

A strongly-connected component in the call graph whose members are not transitively reachable from any anchor and not reached from any anchored code outside the cluster.

- **Why:** More insidious than CE-30 because every module looks fine locally. The smell only emerges at "but who uses any of you, ultimately?". This is the *connected but unimportant* category that pure dead-code analysis cannot detect. (Justification)
- **Check:** Tarjan's SCC algorithm on the call graph; for each SCC of size ≥ 2 with no member in the anchored closure, fire one grouped finding.
- **Tolerate:** Any cluster member marked `@archdo_anchor`; cluster reachable via dynamic dispatch (`apply/3`, `Code.ensure_loaded/1`) — re-run with `--compiled` before treating as actionable.
- **Severity:** `warning`

### CE-32 Public function lacks requirement annotation (opt-in)

Public functions on traceability-required paths without `@requirement`, `@spec_ref`, or `@trace`.

- **Why:** In regulated industries (medical IEC 62304, aviation DO-178C, automotive ISO 26262, financial SOX), every line of code must trace to an approved requirement. Beyond compliance, the discipline forces deliberate intent: writing the requirement reference makes "why does this code exist?" an explicit authorial decision. (Compliance, Intent)
- **Activation:** Opt-in via `.archdo.exs` `traceability_required_paths`.
- **Check:** For each public function in marked paths, verify presence of `@requirement`, `@spec_ref`, or `@trace` immediately preceding the function or at module level.
- **Tolerate:** Function marked `@archdo_no_trace` (rare; usually scaffolding with a deletion deadline).
- **Severity:** `warning`

### CE-33 Dead requirement (opt-in, reverse traceability)

A requirement listed in an external requirements source with no referencing `@requirement` annotation in code.

- **Why:** Closes the traceability loop. CE-32 says "every line of code traces to a requirement"; CE-33 says "every requirement traces to code." Without the reverse direction, requirements can be approved, planned, and forgotten without anyone noticing they were never implemented. (Compliance)
- **Activation:** Opt-in via `.archdo.exs` `requirements_source` (CSV/YAML/JSON file or URL).
- **Check:** Parse requirements source; collect all IDs; scan all `@requirement`/`@spec_ref`/`@trace` annotations; report set difference.
- **Tolerate:** Requirements with status in the configured exempt list (`:cancelled`, `:deferred`, `:out_of_scope`).
- **Severity:** `info`

### CE-34 Volatile call without explicit timeout

Call sites to volatile or non-deterministic dependencies without an explicit timeout argument or option.

- **Why:** Default-infinite or vendor-default timeouts compound under failure — one slow downstream call stalls the calling process indefinitely, propagating to mailbox saturation and global outage. The 5s `GenServer.call` default is a frequent source of cascading failures. (Resilience)
- **Check:** For each call to a tagged volatile module, parse the arg list / opts for timeout-shaped keys (`:timeout`, `:recv_timeout`, `:connect_timeout`, `:request_timeout`, `:pool_timeout`); flag if absent. `GenServer.call/2` with no third argument falls in this set.
- **Tolerate:** Call inside a `Task` with its own supervised timeout; explicitly marked.
- **Severity:** `info`

### CE-35 Volatile boundary without retry / circuit breaker

Modules classified `:volatile` calling external services without any retry library, exponential backoff helper, or circuit breaker visible in the call stack.

- **Why:** Transient failures (network blips, downstream rate limits, vendor 503s) become user-visible errors; repeated failures cascade without protection. The volatility classification said "this dep will fail unpredictably" — ignoring that at the call site is the bug. (Resilience)
- **Check:** For each volatile module's outbound volatile calls, walk up the call graph for retry/breaker patterns (`Retry.with_retries`, `:fuse.ask`, `.archdo.exs` `retry_helpers`/`breaker_helpers`).
- **Tolerate:** Caller is itself an Oban / SQS-consumer job whose queue retries on failure; idempotent operation that doesn't need explicit retry.
- **Severity:** `warning`

### CE-47 Mixed return-shape within a context

Bang public functions (`name!/n`) without a non-bang sibling for similar operations within the same context.

- **Why:** Callers don't know which style to expect; refactoring a function from one style to another silently breaks call sites that handled the other shape. The bang form forces callers into rescue for normal control flow. (Contract Consistency)
- **Check:** Per context module, classify each public function as bang or non-bang; group by base name; flag bang-only public functions and inconsistent ratios across the context.
- **Tolerate:** Marker.
- **Severity:** `warning`

### CE-48 Error category drift

Error atoms or structs that are clearly synonyms scattered across the codebase (e.g., `:not_found`, `:no_user`, `:user_not_found`, `:resource_missing`, `:missing` for the same conceptual failure).

- **Why:** Consumers must pattern-match on every variant; adding a new variant breaks pattern-matching silently in consumers; the error taxonomy has no single source of truth. (Taxonomy Stability)
- **Check:** Apply CE-26-style clustering specifically to the error half of `{:error, _}` returns; flag clusters of ≥ 3 distinct names referring to the same conceptual failure.
- **Tolerate:** Errors are inherently distinct (`:user_not_found` vs `:order_not_found` are legitimately different categories); marker on the cluster.
- **Severity:** `warning`

### CE-49 Catch-all rescue

`rescue _ -> ...` or `rescue _e -> ...` without a filter on exception types.

- **Why:** Swallows specific exceptions the function shouldn't be handling — programming errors (`ArgumentError`, `KeyError`, `MatchError`) get the same treatment as legitimate runtime failures, hiding bugs that should surface immediately. (Fail Fast)
- **Check:** AST scan of `rescue` clauses; flag any with bare wildcard or unfiltered single-variable pattern.
- **Tolerate:** Truly last-line catch in a process boundary (Plug error renderer, GenServer exit-trap); marker `@archdo_boundary_rescue`.
- **Severity:** `warning`

### CE-50 `:ok` return loses information

Functions returning literal `:ok` after operations whose result the caller would plausibly need.

- **Why:** The caller cannot distinguish "operation succeeded with this result" from "operation succeeded with no result." Subsequent operations needing the result must re-fetch; tests cannot assert on what was created. (Information Preservation)
- **Check:** Scan `def`s returning literal `:ok`; if the last meaningful expression is an operation that returns richer information (`Repo.insert/1`, an HTTP call) and that information is discarded, fire.
- **Tolerate:** Operation is genuinely fire-and-forget (cache invalidation, notification dispatch); marker.
- **Severity:** `warning`

### CE-51 PII field without designated handling

Schema fields whose names match PII patterns (`email`, `phone`, `ssn`, `*_token`, `password*`, `address`, `dob`, `national_id`, etc.) without `@derive {Inspect, except: [...]}`, a configured Logger filter, or an explicit handling annotation.

- **Why:** PII leaks via logs (the most common breach surface), `inspect` output in error messages and Observer, telemetry payloads, crash dumps, and Repo query logging. The default `Inspect` impl on schemas reveals every field. (Privacy)
- **Check:** Parse Ecto schemas; for each field matching the PII pattern list (configurable), verify presence of one of the three mitigations.
- **Tolerate:** Field is intentionally public (`display_name`, `username`); marker via custom attribute or `.archdo.exs`.
- **Severity:** `warning`

### CE-52 Schema without retention policy

Ecto schemas representing user-generated data (has `inserted_at`/`created_at` and a user/actor foreign key) without a scheduled cleanup job, retention annotation, or membership in `infinite_retention_schemas`.

- **Why:** Unbounded data growth; under privacy law (GDPR Article 5(1)(e), CCPA §1798.105) unjustified indefinite retention is a compliance issue. Operationally, tables grow until queries slow down or storage fills up. (Privacy, Operability)
- **Check:** Identify candidate schemas via heuristic; scan Oban worker modules, Quantum job definitions, and scheduled GenServers for queries against the schema; check for `@retention :forever` annotation or list membership.
- **Tolerate:** Marker `@retention :forever, reason: "..."`; schema in `infinite_retention_schemas`.
- **Severity:** `warning`

### CE-53 PII schema without right-to-deletion path (opt-in)

PII-bearing schemas (CE-51 set) without a deletion or anonymization function exposed somewhere in the codebase.

- **Why:** GDPR Article 17 (right to erasure), CCPA §1798.105 (right to delete), Brazil LGPD Article 18(VI) all require this path. Without an explicit deletion / anonymization function, compliance is impossible — each subject deletion request becomes an ad-hoc engineering task with non-uniform results. (Privacy, Compliance)
- **Activation:** Opt-in via `.archdo.exs` `gdpr_scope: true`.
- **Check:** For each PII schema, search for a function whose name matches `delete_for_*`, `forget_*`, `anonymize_*`, `erase_*` (configurable) referencing the schema's table or struct.
- **Tolerate:** Schema documented as out-of-scope (employee data under separate legal basis, public profile data, anonymized analytics aggregates); marker.
- **Severity:** `warning`

### CE-54 Domain function that should be a building block

A public function in a `:stable`-classified module whose building-block score (six axes — input closure, determinism, output completeness, totality, side-effect freedom, errors-as-values) is below threshold (default 0.7).

- **Why:** The function lives in a part of the codebase that should consist of building blocks but isn't one yet. Composability suffers, testability degrades, and implicit dependencies on hidden state make the function hard to reason about locally — every consumer must know what's inside. The diagnosis points at the failed axes so the fix is concrete; this is constructive guidance, not a defect. (Composability)
- **Check:** Compute the building-block score per the six-axis algorithm; cross-reference with the module's volatility classification; if the module is `:stable` and the score is below threshold, fire — finding reports which component(s) failed so the fix is concrete.
- **Tolerate:** Function marked `@archdo_not_building_block`; module marked `@archdo_volatility :volatile` overriding the heuristic; generated code.
- **Severity:** `info`

### CE-55 Building-block candidate untested as such

A function with building-block score ≥ 0.9 and no StreamData property test exercising it.

- **Why:** A function at score ≥ 0.9 already has every property property-based testing requires (purity, determinism, closed input domain, total output relation, side-effect freedom). The property test is the natural next move, not "if we have time" — the cost is low and the coverage gain is large. (Testability)
- **Check:** For each function classified `building_block`, search `test/` for an `ExUnitProperties.property` block calling the function.
- **Tolerate:** Function marked `@archdo_no_property`; the property is genuinely hard to express (rare for true building blocks).
- **Severity:** `info`

### CE-56 Effect leak in a near-building-block function

A function whose building-block score *would* be ≥ 0.9 except for a single side-effect call (typically `Logger`, `:telemetry.execute`, or `Phoenix.PubSub.broadcast`).

- **Why:** Sharper diagnostic than "improve this function" — *this one call* is keeping a building block from existing. The fix is mechanical conceptually (move the effect up the call stack to the orchestrating layer). (Composability)
- **Check:** For each function whose components other than side-effect-freedom score ≥ 0.9, count side-effect calls; if exactly one or two and they're observability-only (Logger, telemetry, PubSub), fire.
- **Tolerate:** The effect is essential to the function's contract (the function's job is *to log*); marker.
- **Severity:** `info`

### CE-57 Building-block candidate accepts unguarded input

A near-building-block function whose public signature accepts unguarded input — illegal inputs crash with `MatchError` / `FunctionClauseError` instead of returning `{:error, _}`.

- **Why:** Totality is the building-block axis that fails most often via "I'll match the happy case and let the rest crash." A building-block contract requires the caller can pass any value of the spec'd domain and get a defined response — exception flow disqualifies the function from memoization, parallelization, and distribution. (Totality)
- **Check:** For functions otherwise scoring ≥ 0.9, verify either exhaustive pattern coverage of the spec'd input domain or a final catch-all clause returning `{:error, _}` rather than raising.
- **Tolerate:** The unguarded input is a genuine programming error, not a domain failure (caller-side bug); marker `@archdo_intentional_crash`.
- **Severity:** `info`

---

## Rule Summary

| Category | Count |
|----------|-------|
| Boundaries | 33 |
| Public API | 3 |
| Single Source of Truth | 6 |
| Coupling & Abstraction | 29 |
| OTP Process Architecture | 71 |
| Module Quality | 99 |
| Test Architecture | 31 |
| Event Sourcing | 9 |
| State Machine | 6 |
| Composition | 6 |
| Native Interop | 4 |
| Change Economy | 32 |
| **Total** | **329** |

Counts are derived from the rule registries (`Archdo.Rules.phase1_rules/0`, `graph_rules/0`, `project_rules/0`, `compiled_rules/0`); each rule is counted under its primary category only.

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
