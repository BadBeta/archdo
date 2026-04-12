# Archdo — Architectural Quality Rules for Elixir

> Rules that complement Credo, Dialyzer, and Sobelow by checking **system architecture** and **test coverage quality** — the gap none of them cover.

## Design Philosophy

These rules must be:
- **Universal** — valid across Phoenix contexts, event sourcing, state machines, OTP, and Ash domains
- **Tolerant** — common patterns in quality Elixir projects on GitHub must pass
- **Actionable** — each rule produces a clear diagnostic with a suggested fix
- **Checkable** — statically via AST analysis, or heuristically with reasonable confidence

Rules are organized by architectural concern. Each rule has:
- A short name and description
- **Why** — the principle it enforces
- **Check** — how to detect violations
- **Tolerate** — known exceptions that should not be flagged
- **Severity** — `error` (always wrong), `warning` (usually wrong), `info` (worth reviewing)

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

**The three illegal directions:**
1. Domain -> Interface (domain must never know about web/CLI)
2. Infrastructure -> Interface (adapters must not reference controllers/views)
3. Domain -> Infrastructure concrete modules (domain references behaviours, not implementations)

- **Why:** Core principle of Clean/Hexagonal architecture. Domain modules that reference web/framework modules cannot be reused, tested independently, or survive framework changes. Infrastructure that references interface modules creates cross-cutting coupling that defeats layering. Domain referencing concrete infrastructure (not behaviours) prevents testing and swapping. (SOLID-D, Hexagonal Architecture, Ports & Adapters)
- **Check:** Build a module dependency graph from `alias`, `import`, `use`, and function calls. Flag edges that flow in illegal directions:
  - **Domain -> Interface:** `MyApp.*` (domain) referencing `MyAppWeb.*`, `Phoenix.Controller`, `Phoenix.LiveView`, `Phoenix.Channel`, `Plug.*`
  - **Domain -> Framework packages:** `MyApp.*` (domain, non-schema) importing or aliasing `Phoenix.HTML`, `Phoenix.LiveView.Socket`, `Phoenix.Router`
  - **Infrastructure -> Interface:** Adapter/infrastructure modules referencing `MyAppWeb.*`
  - **Schema -> upward:** Schema modules calling context functions or web modules
- **Tolerate:**
  - `Ecto.Changeset` usage in web layer (widely accepted for forms)
  - Schema modules referenced from web layer (for view rendering)
  - `Phoenix.PubSub` in domain modules (it's a general-purpose tool, not web-specific)
  - Shared config modules that span layers
  - `Ecto` in domain (Ecto is a domain tool in Phoenix conventions — schemas and changesets are domain objects)
  - Phoenix contexts calling `Repo` directly (standard Phoenix pattern — full hex separation is opt-in via behaviours)
- **Severity:** `error`

### 1.1b Hex Package Dependencies Must Respect Layers

Domain modules must not depend on hex packages that are framework/interface-specific.

- **Why:** If your domain context `use`s or `import`s a Phoenix-specific package, the domain cannot be extracted, reused in a CLI tool, or tested without Phoenix. The domain should depend only on general-purpose libraries (Ecto, Jason, Decimal, etc.) and its own behaviours. (Hexagonal Architecture, Framework Independence)
- **Check:** Flag `alias`, `import`, or `use` of framework-specific packages from domain modules:
  - Phoenix packages: `Phoenix.HTML`, `Phoenix.LiveView`, `Phoenix.LiveComponent`, `Phoenix.Router.Helpers`
  - Web-specific: `Plug.Conn`, `Plug.Upload`
  - Detect by cross-referencing `mix.exs` deps list — packages tagged as web/interface-only should not appear in domain module dependencies
- **Tolerate:**
  - `Phoenix.PubSub` (general-purpose)
  - `Phoenix.Ecto` (domain-adjacent)
  - `Ecto.*` (accepted as domain in Phoenix convention)
  - Ash Framework modules (their own architectural model)
- **Severity:** `warning`

### 1.2 Context Encapsulation

External modules must not reach into a context's internal modules. Access goes through the context's public API.

- **Why:** Contexts are bounded contexts — their internal structure is an implementation detail. Bypassing the public API creates hidden coupling that breaks when internals change. (Single Responsibility, Information Hiding)
- **Check:** Identify context boundaries (top-level modules under `MyApp.*`). Flag calls from outside a context to modules nested inside it (e.g., `MyApp.Accounts.UserQuery` called from `MyAppWeb.UserController`). Internal modules are those marked `@moduledoc false` or nested more than one level under the context.
- **Tolerate:**
  - Schema modules referenced for struct pattern matching or Ecto associations
  - `defdelegate` targets (the context explicitly exports these)
  - Shared types/structs that contexts explicitly export
  - Ash Framework resources referenced through their Domain
- **Severity:** `warning`

### 1.3 No Circular Dependencies Between Contexts

Context A must not depend on Context B if B already depends on A.

- **Why:** Circular dependencies make it impossible to reason about, test, or deploy contexts independently. They indicate mixed responsibilities. (Acyclic Dependencies Principle)
- **Check:** Build a directed graph of context-to-context calls. Detect cycles. Report the shortest cycle path.
- **Tolerate:**
  - Shared foundational contexts (e.g., `Accounts`) depended on by many others are fine — cycles are the problem, not fan-in
  - PubSub-mediated communication (context A publishes, context B subscribes) is not a direct dependency
- **Severity:** `error`

### 1.5 Schema Ownership

Each Ecto schema should have one owning context. Other contexts should not directly reference (alias, pattern-match, or construct) schemas they don't own.

- **Why:** Schemas are the data shape of a context. When another context constructs `%MyApp.Accounts.User{}` directly, it's bypassing the Accounts API and creating a hidden coupling that breaks when the schema changes. Cross-context access should go through the owning context's API. (Bounded Context, Information Hiding)
- **Check:** Build a map of `Schema -> owning context` (the context module nearest to the schema in the namespace). Flag references to a schema from outside its owning context, except:
  - Reading the struct (matching `%Schema{}` to extract data) is OK at boundaries
  - Direct construction (`%Schema{field: value}`) from another context is NOT OK
  - `alias` of a foreign schema is a yellow flag (might be just for type specs)
- **Tolerate:**
  - Schema references from the owning context's interface (web layer for that context)
  - Test fixtures and factories
  - Read-side projections in event sourcing
- **Severity:** `warning`

### 1.6 No Cross-Cutting Concerns in Domain

Logger, Telemetry, and other infrastructure concerns should not be sprinkled throughout domain modules — they belong at boundaries or in middleware.

- **Why:** When `Logger.info` is everywhere in domain code, the domain is no longer pure or testable in isolation. The test must capture log output, the domain knows about logging configuration, and changing the log format requires touching every domain module. Cross-cutting concerns should be at the seam: in adapters (telemetry on Repo calls), middleware (telemetry on Phoenix endpoints), or via Telemetry events the domain emits without coupling to handlers. (Cross-Cutting Concerns, Pure Core)
- **Check:** Flag domain modules (under `MyApp.*`, not `MyAppWeb.*`, not adapters) that:
  - Call `Logger.info`, `Logger.debug`, `Logger.warning`, `Logger.error` more than 3 times
  - Call `Telemetry.execute` directly (should use `:telemetry.execute` only at infrastructure boundaries)
  - Have `require Logger` AND make calls in business-logic functions (not just on errors)
- **Tolerate:**
  - `Logger.error` in `rescue` or `catch` clauses (error logging at the moment of failure is acceptable)
  - Adapter modules (they ARE the boundary)
  - Modules in an explicit `Telemetry`, `Observability`, or `Logging` namespace
- **Severity:** `info`

### 1.4 No Direct Repo Access From Interface Layer

Controllers, LiveViews, channels, and CLI handlers must not call `Repo` directly.

- **Why:** The Repo is an infrastructure detail. Interface modules should delegate to contexts, which own the data access. Direct Repo access scatters query logic and bypasses business rules. (Layered Architecture)
- **Check:** Flag `Repo.` calls (or `alias MyApp.Repo` / `import Ecto.Query`) in modules under `MyAppWeb.*` or any module using `Phoenix.Controller`, `Phoenix.LiveView`, `Phoenix.Channel`.
- **Tolerate:**
  - Test support modules and test helpers
  - Database migration modules
  - One-off scripts in `priv/`
- **Severity:** `warning`

---

## 2. Public API Discipline

### 2.1 Module Documentation Presence

Every module must have `@moduledoc` — either documentation or explicit `false`.

- **Why:** Missing `@moduledoc` is ambiguous — is this a public module with missing docs, or an internal module that forgot to mark itself private? Explicit is better than implicit. (Already a Credo check, but architectural significance is higher — it defines the public/private boundary.)
- **Check:** Flag modules without `@moduledoc`.
- **Tolerate:** Test modules, protocol implementations (`defimpl`), mix tasks (these have `@shortdoc` instead)
- **Severity:** `info`

### 2.2 Public Functions Have Type Specs

All public functions in documented modules (`@moduledoc` is not `false`) must have `@spec`.

- **Why:** Specs define the contract. Without them, Dialyzer can't check callers, documentation is incomplete, and behaviour implementations can't be validated for Liskov substitution. (SOLID-L, Design by Contract)
- **Check:** Flag `def` functions without a corresponding `@spec` in modules where `@moduledoc` is not `false`.
- **Tolerate:**
  - Callback implementations (`@impl true`) — the spec is on the `@callback`
  - `defdelegate` — the spec is on the target function
  - Phoenix controller actions and LiveView callbacks (specs are on the behaviour)
  - Test modules
- **Severity:** `warning`

### 2.3 No External Calls to Private Modules

Modules marked `@moduledoc false` must not be called from outside their parent namespace.

- **Why:** `@moduledoc false` signals "this is an implementation detail." Calling it from outside defeats the encapsulation boundary. (Information Hiding, Open/Closed)
- **Check:** Find all modules with `@moduledoc false`. Flag function calls to them from modules outside their parent namespace. E.g., `MyApp.Accounts.Impl.do_thing()` called from `MyApp.Billing` is a violation.
- **Tolerate:**
  - Calls from the parent context module itself (that's the intended access path)
  - Calls from sibling modules within the same context namespace
  - Protocol implementations referencing internal types
  - Test modules testing the parent context's public API indirectly
- **Severity:** `warning`

---

## 3. Single Source of Truth

### 3.1 Duplicated Code (Type-2 Clones)

Functions with structurally identical bodies should be unified — the duplication is a maintenance liability waiting to be triggered.

- **Why:** Type-2 clones (functions with the same shape but possibly renamed variables) start as a convenient copy-paste and end as the most painful kind of duplication. Bug fixes have to be applied in N places and the copies inevitably drift apart, so the same logic produces subtly different results in different parts of the system.
- **Check:** Normalize each function body (strip metadata, replace variable names with positional placeholders), hash, group by hash. Functions sharing a hash with size ≥ 15 AST nodes are flagged. Standard OTP/Phoenix callbacks (`init`, `handle_call`, `mount`, `render`, etc.) are excluded — they're expected to be similar across modules.
- **Tolerate:**
  - Coincidentally similar functions in unrelated modules that should evolve independently
  - Trivially small functions (excluded by the size threshold)
  - Standard callbacks
- **Severity:** `warning`

### 3.2 No Scattered Configuration

Configuration values (URLs, timeouts, feature flags, credentials) must be defined in one place, not hardcoded across modules.

- **Why:** Hardcoded values in multiple modules are impossible to manage across environments and easy to forget when changing. (Single Source of Truth)
- **Check:**
  - Flag identical string literals (URLs, API keys patterns) appearing in 2+ non-test modules
  - Flag `Application.get_env` calls for the same key in multiple modules (centralize in a config module)
  - Flag `System.get_env` calls outside `config/runtime.exs` (except in explicit config modules)
- **Tolerate:**
  - Common atoms, module names, and standard library references
  - Test fixtures and factory data
  - Documentation strings
- **Severity:** `warning`

### 3.3 Libraries Must Accept Configuration as Arguments

Library modules (those published as hex packages or in `lib/` without `MyApp` prefix) must not use `Application.get_env` for their own configuration.

- **Why:** `Application.get_env` creates a global mutable dependency. Libraries should accept config through function arguments, child_spec options, or start_link options. This allows multiple instances with different configs and makes testing straightforward. (Official Elixir Library Guidelines, Dependency Inversion)
- **Check:** Flag `Application.get_env` / `Application.fetch_env!` in modules that don't belong to the main application namespace.
- **Tolerate:**
  - Application callback modules (`def start/2`)
  - Modules that explicitly wrap config for the application (e.g., `MyApp.Config`)
- **Severity:** `warning`

### 3.4 Similar Functions (Type-3 Clones)

Functions with similar but not identical bodies — copy-paste-and-edit clones — should be unified before they drift apart.

- **Why:** Type-3 clones are functions that share most of their structure but differ in a few places. They are the most expensive form of duplication: bug fixes have to be re-applied per copy, the variations slowly disagree, and reading the code becomes "compare these two and figure out which differences matter." Refactoring them early is much cheaper than later.
- **Check:** For each function, build a "shingle" fingerprint (sliding windows of 5 normalized AST tokens). Compare fingerprint pairs with Jaccard similarity; flag pairs with similarity ≥ 0.75 and size ≥ 25 nodes that aren't already exact duplicates (rule 3.1).
- **Tolerate:**
  - Functions that are coincidentally similar but model different concepts (e.g. two parsers with similar shapes)
  - Standard callbacks (excluded from analysis)
- **Severity:** `info`

### 3.5 Reinvented Enumerable

Recursive functions that index into a list with `Enum.at/2` are reinventing iteration primitives — usually with O(n²) complexity.

- **Why:** `Enum.at/2` is O(n) for lists. A recursive function that calls `Enum.at/2` on every iteration becomes O(n²) — fine for tiny lists but a quadratic surprise on real data. The pattern also reinvents iteration primitives Elixir already provides via `Enum.reduce`, `Enum.with_index`, and `Stream`, which read better and have better complexity.
- **Check:** Flag functions that are both recursive (call themselves) and contain `Enum.at/2` calls.
- **Tolerate:**
  - Non-recursive code that genuinely needs random access
- **Severity:** `info`

### 3.6 No Duplicated Validation Logic

The same validation rule must not appear in both the web layer and the domain layer.

- **Why:** Duplicated validations diverge over time. One gets updated, the other doesn't, leading to inconsistent behaviour. Validate at the domain boundary; the web layer formats errors for display. (DRY where it matters)
- **Check:** Heuristic — detect identical or near-identical `validate_*` function calls, `Ecto.Changeset` validations, or regex patterns appearing in both `MyAppWeb.*` and `MyApp.*` modules.
- **Tolerate:**
  - Client-side validations (JavaScript) that duplicate server-side rules for UX — different layers entirely
  - LiveView form validations that delegate to the same changeset function (that's correct — single source)
- **Severity:** `info`

> **History:** rule 3.1 originally referred to "No Duplicated Validation Logic". It was renumbered to 3.6 in 2026-04 when `duplicated_code` (the canonical Type-2 clone detector) became the canonical 3.1.

---

## 4. Abstraction Quality

### 4.1 Behaviour Size Limit

Behaviours should define a focused interface, not a god-interface.

- **Why:** Large behaviours force implementors to provide callbacks they don't need, violating Interface Segregation. They're harder to implement, mock, and understand. (SOLID-I)
- **Check:** Flag `@callback` definitions — warn when a behaviour defines more than **5** callbacks.
- **Tolerate:**
  - Well-established framework behaviours (e.g., `GenServer` has 7 callbacks, but most are optional)
  - Behaviours with `@optional_callbacks` — count only required callbacks
  - Adapter behaviours for complex external services where the surface area is inherently large
- **Severity:** `info`

### 4.2 No Single-Implementation Protocols

Protocols implemented for only one type (with no `Any` fallback) suggest over-engineering.

- **Why:** A protocol is polymorphic dispatch. With one implementation, a direct function call is simpler and faster. Protocols have real runtime cost (consolidation, dispatch). (YAGNI, Simple Design)
- **Check:** Count `defimpl` blocks per protocol. Flag protocols with exactly one implementation and no `Any` fallback.
- **Tolerate:**
  - Protocols defined in libraries (consumers add implementations)
  - Protocols with a clear extension point documented in `@moduledoc`
  - New code where more implementations are planned (hard to detect — rely on `# TODO` or similar)
- **Severity:** `info`

### 4.3 No Type-Dispatching Case Statements

`case`/`cond` dispatching on type atoms where each branch does the same conceptual operation suggests missing polymorphism.

- **Why:** Adding a new type requires modifying every dispatch site. Behaviours or protocols let you add types without touching existing code. (SOLID-O, Open/Closed)
- **Check:** Heuristic — detect `case variable do :type_a -> ... :type_b -> ... end` patterns where branches call similar functions or return similar structures. Especially flag if the same dispatch pattern appears in multiple functions.
- **Tolerate:**
  - Pattern matching on message types in `handle_info`/`handle_cast` (idiomatic OTP)
  - Pattern matching on error tuples (`{:ok, _}` / `{:error, _}`)
  - Small, stable enumerations (2-3 cases) that are unlikely to grow
  - Ecto migration operations, config parsing
- **Severity:** `info`

### 4.4 External Dependencies Behind Behaviours

Direct calls to external service clients (HTTP, email, SMS, payment, file storage) from domain modules should go through a behaviour boundary.

- **Why:** External dependencies are the most volatile part of a system. Wrapping them in behaviours enables testing with Mox, swapping providers, and isolating failures. (SOLID-D, Hexagonal Architecture, Replaceability)
- **Check:** Flag calls to known HTTP clients (`HTTPoison`, `Finch`, `Req`, `Tesla`), email libraries (`Swoosh`, `Bamboo`), and cloud SDKs from modules that are not themselves marked as infrastructure/adapter modules.
- **Tolerate:**
  - Infrastructure adapter modules (they ARE the implementation)
  - Phoenix endpoint configuration
  - Mix tasks and scripts
  - Modules explicitly in an `Infrastructure` or `Adapters` namespace
- **Severity:** `warning`

### 4.5 Minimal Coupling at Module Interfaces

Connections between modules must share only what they need — nothing more.

- **Why:** Every unnecessary dependency is entanglement that makes both modules harder to change, test, and reason about independently. When module A passes an entire struct to module B but B only reads two fields, A and B are coupled to the struct's full shape. When a context returns `%Ecto.Changeset{}`, every caller is coupled to Ecto. When `import` pulls in 40 functions but you use 2, you've created 38 invisible dependencies. This is the most fundamental coupling rule: **the narrowest possible interface between any two modules.** (Interface Segregation, Law of Demeter, Minimal Coupling)
- **Check:**
  - **Import breadth:** Flag `import Module` without `:only` — pulls in entire module surface. Flag `import Module, only: [...]` where the list has 5+ functions (consider aliasing instead).
  - **Struct pass-through across boundaries:** Heuristic — flag functions that receive a struct parameter *from another context* but only access 1-2 fields. When crossing context boundaries, prefer passing individual values. Within a context or pipeline, passing the full struct is idiomatic.
  - **Leaking internal types:** Flag public context functions (modules matching `MyApp.*` top-level contexts) whose `@spec` return types reference `Ecto.Changeset`, `Ecto.Multi`, `Ecto.Query`, or other infrastructure types. Context APIs should return domain types (`{:ok, %User{}}`, `{:error, :not_found}`), not framework types.
  - **Coupling fan-out:** Flag modules that `alias` more than **10** other modules (high coupling — the module knows too much about the system).
  - **Cross-context struct dependency:** Flag modules in one context that pattern-match on or construct structs defined in another context. Contexts should communicate via data (maps, simple tuples) or shared types, not by reaching into each other's struct definitions.
- **Suggest:**
  - Replace `import Module` with `alias Module` and explicit `Module.function()` calls
  - For `import` with `:only`, if using > 3 functions, consider whether the calling module should depend on the imported module at all
  - At context boundaries, accept individual values: `def notify(email, name)` not `def notify(user)`
  - Return `{:ok, result}` / `{:error, reason}` from context APIs, not Ecto types
  - For cross-context data, define a shared protocol or use plain maps at the boundary
- **Tolerate:**
  - `import Ecto.Query` in context/query modules (ubiquitous, accepted pattern)
  - `import Ecto.Changeset` in schema/changeset modules
  - `import Phoenix.LiveView` / `import Phoenix.Component` in LiveView modules
  - Test modules importing assertion helpers
  - `import Bitwise` and similar small utility modules
  - Passing structs within the same context (internal coupling is acceptable)
  - **Pipeline structs:** Passing a struct through a pipeline where each step reads/modifies its own concern is a core Elixir idiom, not a coupling violation. This includes `Plug.Conn` through Plug pipelines, `Ecto.Changeset` through validation chains, `%Env{}` or `%Context{}` accumulator structs, and any `struct |> step1() |> step2() |> step3()` pattern. The struct is the *contract* — each step depends on the struct's interface, not on the other steps. This is by design.
  - Custom accumulator/context structs (e.g., `%BuildContext{}`, `%Pipeline{}`) passed through a series of transformation functions — same principle as Plug.Conn
- **Severity:** `warning` (import breadth, leaking types), `info` (struct pass-through, fan-out)

### 4.7 God Context Detection

A context with too many sub-modules is doing too much.

- **Why:** A well-shaped context has 5-15 sub-modules covering related concerns. When you see 30+ files under `lib/my_app/billing/`, the context has become a junk drawer — it's actually 3-4 contexts merged together. Splitting reveals which boundaries you're missing. (Bounded Context, High Cohesion)
- **Check:** Count `.ex` files under each top-level context directory (e.g., `lib/my_app/accounts/**/*.ex`). Flag contexts with > **20** files (warning) or > **40** (info, suggesting decomposition).
- **Tolerate:**
  - Contexts that intentionally aggregate (e.g., `lib/my_app/web/` for view helpers)
  - Generated code directories (protobuf, OpenAPI clients)
  - Schema-heavy contexts where most files are individual schemas
- **Severity:** `info`

### 4.6 No Unnecessary Module Dependencies

Modules should not alias or import modules they don't use, and should not depend on modules just for one constant or type.

- **Why:** Every `alias` or `import` is a dependency arrow in the module graph. Unused or barely-used dependencies create false coupling signals and make refactoring harder — you can't move a module without checking all its (possibly unnecessary) dependents. (Minimal Dependency, YAGNI applied to coupling)
- **Check:**
  - Flag `alias Module` where `Module` is never referenced in the rest of the file
  - Flag `import Module, only: [fun: arity]` where `fun` is never called in the file
  - Heuristic: flag modules that `alias` another module but only use it once — consider using the fully qualified name inline instead
- **Tolerate:**
  - `alias` used for struct pattern matching (`%Module{}`) even if only once
  - `alias __MODULE__` patterns
  - Generated code
- **Severity:** `info`

---

## 5. Process Architecture (OTP)

OTP is the backbone of Elixir architecture. The supervision tree IS the architecture — it encodes dependency order, coupling, failure domains, and recovery strategy. These rules are first-class concerns, not secondary to module-level checks.

### 5A. Process Lifecycle

#### 5.1 All Long-Running Processes Must Be Supervised

No bare `spawn`, `spawn_link`, or unlinked `GenServer.start` for processes that should persist.

- **Why:** Unsupervised processes die silently. No restart, no logging, no visibility in Observer or LiveDashboard. The supervision tree IS the architecture — processes outside it are invisible. (OTP Fundamentals, Error Kernel)
- **Check:** Flag in non-test code:
  - `spawn/1`, `spawn/3`, `spawn_link/1`, `spawn_link/3`
  - `GenServer.start/2,3` (the non-link variant — process not linked to caller)
  - `Agent.start/1,2` (the non-link variant)
  - `Task.start/1`, `Task.start_link/1` (prefer `Task.Supervisor.start_child`)
- **Suggest:** Use `start_link` under a Supervisor. For dynamic processes, use `DynamicSupervisor`. For fire-and-forget work, use `Task.Supervisor.start_child/2`.
- **Tolerate:**
  - Test helper processes
  - Short-lived `Task.async`/`Task.await` pairs within a single function scope
  - Processes explicitly used for benchmarking or profiling
  - `spawn_monitor` where the caller explicitly handles `{:DOWN, ...}`
- **Severity:** `warning`

#### 5.2 No Unnecessary Processes

Modules that wrap pure functions in a GenServer without needing state, concurrency, or fault isolation.

- **Why:** Official Elixir docs: "A GenServer must never be used for code organization purposes." Valid reasons to spawn a process: (1) mutable state, (2) concurrent execution, (3) failure isolation, (4) resource management. If none apply, use a module with functions. Each process costs ~327 words of heap, adds message-copy overhead, and serializes all access. (Official Anti-Patterns, Saša Jurić "To Spawn or Not to Spawn")
- **Check:** Heuristic — flag GenServer modules where:
  - `init/1` returns empty or trivial state (`%{}`, `[]`, `nil`, `:ok`, a constant)
  - No state is mutated across callbacks (each call is independent)
  - All callbacks could be pure functions (no `send`, no process interaction, no external effects)
- **Suggest:** Extract logic into a plain module with functions. If state is needed, consider ETS or `persistent_term`.
- **Tolerate:**
  - Processes that exist for rate limiting, connection pooling, or ordered execution
  - Processes that need to be registered for discovery
  - Processes acting as supervisors or coordinators
- **Severity:** `info`

#### 5.3 Agent Misuse — When ETS Would Be Better

Agent used as a read-heavy cache or shared data store where ETS would be more appropriate.

- **Why:** Agent serializes ALL access — reads block behind writes. For read-heavy workloads, ETS with `read_concurrency: true` is orders of magnitude faster. Agent also blocks the caller while executing the anonymous function inside the Agent process. (Process Bottleneck)
- **Check:** Heuristic — flag Agent modules where:
  - State is a Map or keyword list
  - Module name suggests caching (`*Cache*`, `*Store*`, `*Registry*`)
  - Ratio of `Agent.get` calls to `Agent.update` is high (read-heavy)
  - State grows unboundedly (accumulating data without cleanup)
- **Suggest:** Use ETS with `[:set, :named_table, :public, read_concurrency: true]` for read-heavy shared state. Use `:persistent_term` for configuration that rarely changes.
- **Tolerate:**
  - Small-scale Agent usage in applications with low concurrency
  - Agent as a simple configuration holder during startup
- **Severity:** `info`

### 5B. Supervision Tree Design

#### 5.4 No Flat Supervision Trees

All processes under a single supervisor without sub-grouping.

- **Why:** No failure isolation between unrelated subsystems. One bad child's restarts consume the `max_restarts` budget for the entire application. Cannot apply different restart strategies to different groups. Makes it impossible to reason about failure domains. (Error Kernel, Defense in Depth)
- **Check:** Flag Supervisor `init/1` or `start_link` calls with more than **7** direct children and no nested Supervisor children.
- **Suggest:** Group related processes under sub-supervisors. Infrastructure (Repo, PubSub, Telemetry) under one supervisor. Business logic workers under another. Web endpoint at the top level.
- **Tolerate:**
  - Small applications with genuinely few processes
  - Generated Phoenix application supervision tree (these are typically well-structured)
- **Severity:** `info`

#### 5.5 Supervision Strategy Matches Child Coupling

The restart strategy must match the actual dependency relationships between children.

- **Why:** `:one_for_one` with coupled children means one restarts but its dependent doesn't, leading to stale references. `:one_for_all` with independent children means unnecessary restarts. Wrong strategy = silent corruption or wasted work. (Supervision Semantics)
- **Check:** Heuristic — analyze child modules under a supervisor:
  - If child A calls child B (detected via module call graph) and strategy is `:one_for_one`, flag for review
  - If children share an ETS table and strategy is `:one_for_one`, flag for review
  - If children are independent and strategy is `:one_for_all`, flag for review
- **Suggest:**
  - `:one_for_one` — children are completely independent
  - `:one_for_all` — children share state, all must restart together
  - `:rest_for_one` — pipeline/dependency chain, later children depend on earlier ones
- **Tolerate:**
  - Cases where the strategy is intentionally conservative (`:one_for_all` as a safety net)
- **Severity:** `info`

#### 5.6 Tune max_restarts / max_seconds

Supervisors using default `max_restarts: 3, max_seconds: 5` without explicit consideration.

- **Why:** The default (3 restarts in 5 seconds) is very aggressive. A temporary network blip causing 4 rapid failures kills the entire supervisor and escalates to its parent. For processes connecting to external services, the default is almost always too tight. (Resilience, Cascading Failure Prevention)
- **Check:** Flag `Supervisor.start_link` or `Supervisor.init` calls without explicit `max_restarts` and `max_seconds` options.
- **Suggest:** Tune based on failure mode: `max_restarts: 10, max_seconds: 60` for processes with external dependencies. Document the reasoning.
- **Tolerate:**
  - Leaf supervisors with purely local children (defaults may be appropriate)
  - Phoenix-generated supervision trees (well-considered defaults)
- **Severity:** `info`

#### 5.7 Restart Type Matches Process Nature

Process restart type (`:permanent`, `:transient`, `:temporary`) must match the process's intended lifecycle.

- **Why:** Permanent one-shot tasks restart in an infinite loop and hit `max_restarts`, killing the supervisor. Transient long-running workers that crash abnormally don't restart, causing silent service loss. (Supervision Contract)
- **Check:**
  - Flag Task-like modules (modules with `run/0,1` or single-use patterns) with `restart: :permanent`
  - Flag GenServer modules (long-running by nature) with `restart: :temporary`
  - Flag child specs where `restart:` is not explicitly set (relying on the default `:permanent` without consideration)
- **Suggest:**
  - `:permanent` — processes that must always run (most GenServers, Supervisors)
  - `:transient` — processes that may finish normally but should restart on crashes (workers processing a bounded job)
  - `:temporary` — processes that should never restart (one-shot tasks, request-scoped work)
- **Tolerate:**
  - DynamicSupervisor children where restart is managed by the parent logic
- **Severity:** `info`

### 5C. GenServer Internals

#### 5.8 No Blocking Work in init/1

`init/1` must not perform I/O, network calls, or long computations.

- **Why:** `init/1` blocks the supervisor startup. All subsequent children wait. If the call times out, the supervisor's restart logic kicks in. Per Fred Hebert: "Only local dependencies can be guaranteed at initialization — remote dependencies should NOT be." (Supervisor Startup, "It's About the Guarantees")
- **Check:** Flag in `init/1` function bodies:
  - HTTP client calls (`HTTPoison`, `Finch`, `Req`, `Tesla`, `:httpc`)
  - `Repo` calls (database queries)
  - `File.read`/`File.write` or other file I/O
  - `Process.sleep`/`:timer.sleep`
  - Any module calls to known external service adapters
- **Suggest:** Use `{:ok, state, {:continue, :init_async}}` and perform the work in `handle_continue/2`:
  ```elixir
  def init(args) do
    {:ok, %{data: nil}, {:continue, :load_data}}
  end
  def handle_continue(:load_data, state) do
    data = ExternalService.fetch()
    {:noreply, %{state | data: data}}
  end
  ```
- **Tolerate:**
  - ETS table creation in `init/1` (local, fast)
  - Reading from `Application.get_env` or `:persistent_term` (local, fast)
  - `Registry` lookups (local)
- **Severity:** `warning`

#### 5.9 No Blocking in GenServer Callbacks

Long-running operations (HTTP calls, heavy computation, sequential external calls) must not block GenServer callbacks.

- **Why:** The GenServer cannot process any other messages while blocked. All callers queue up. For `handle_call`, callers timeout (default 5000ms). A single slow HTTP call makes the entire server unresponsive. (Bottleneck, Availability)
- **Check:** Flag in `handle_call`, `handle_cast`, `handle_info`, `handle_continue` bodies:
  - HTTP client calls
  - `Repo` calls with potentially large result sets
  - `Enum.each`/`Enum.map` over external service calls
  - `Process.sleep`/`:timer.sleep`
  - `File.read`/`File.write` for potentially large files
- **Suggest:** Delegate to a supervised Task:
  ```elixir
  def handle_call(:fetch, from, state) do
    Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn ->
      ExternalService.fetch()
    end)
    {:noreply, Map.put(state, :pending_from, from)}
  end
  def handle_info({ref, result}, state) do
    GenServer.reply(state.pending_from, result)
    Process.demonitor(ref, [:flush])
    {:noreply, Map.delete(state, :pending_from)}
  end
  ```
- **Tolerate:**
  - Quick ETS lookups
  - Simple `Repo.get` calls (fast, single-row lookups) in non-critical paths
  - `handle_continue` performing one-time setup after init
- **Severity:** `warning`

#### 5.10 GenServer Callbacks Should Delegate to Pure Functions

Business logic in GenServer callbacks should be delegated to pure functions.

- **Why:** Logic embedded in callbacks cannot be tested without starting a process. Pure functions can be tested with simple input/output assertions. The GenServer handles process mechanics (state, messages, lifecycle); pure functions handle domain logic (calculations, validations, transformations). (Pure Core/Impure Shell, Testability)
- **Check:** Heuristic — flag GenServer callback functions that exceed **15 lines** or contain complex branching (nested `case`/`cond`/`with`).
- **Suggest:** Extract the logic:
  ```elixir
  # Instead of logic in handle_call:
  def handle_call({:process, data}, _from, state) do
    {result, new_state} = MyModule.Logic.process(state, data)
    {:reply, result, new_state}
  end
  ```
- **Tolerate:**
  - Simple callbacks that just update state or delegate to one function
  - `handle_info` for timeout/monitoring messages that are inherently process-level
- **Severity:** `info`

#### 5.11 No receive Inside GenServer Callbacks

`receive` blocks must not appear inside any GenServer callback.

- **Why:** Official docs: "You should never call your own 'receive' inside GenServer callbacks as doing so will cause the GenServer to misbehave." The `receive` consumes messages meant for GenServer's internal handling (`:$gen_call`, `:$gen_cast`, system messages), corrupting its state machine. (GenServer Contract)
- **Check:** AST match for `receive` blocks inside `handle_call`, `handle_cast`, `handle_info`, `handle_continue`, `init`.
- **Suggest:** Use `handle_info` to receive responses asynchronously, or use Task.async with proper await patterns.
- **Tolerate:** None — this is always a bug.
- **Severity:** `error`

#### 5.12 Use handle_continue Instead of send(self()) in init

`send(self(), ...)` in `init/1` has a race condition; use `{:continue, ...}` instead.

- **Why:** Between `init/1` returning and `handle_info` processing the self-sent message, other messages can arrive if the process is already registered. `handle_continue` is guaranteed to run before any other message. (Race Condition, OTP Contract)
- **Check:** Flag `send(self(), ...)` inside `init/1`.
- **Suggest:** Replace with `{:ok, state, {:continue, :post_init}}` and `handle_continue(:post_init, state)`.
- **Tolerate:** None — `handle_continue` exists specifically to replace this pattern (since OTP 21).
- **Severity:** `warning`

#### 5.13 Cast Used Where Call Is Needed

`GenServer.cast` used for operations where the caller needs to know the outcome.

- **Why:** Cast is fire-and-forget. If the operation fails, the caller never knows. No backpressure — callers can overwhelm the server's mailbox because casts never block. Errors are swallowed silently. (Error Visibility, Backpressure)
- **Check:** Heuristic — flag `handle_cast` callbacks that contain:
  - `Repo` operations (insert, update, delete — these can fail)
  - Validation logic (callers should know if validation fails)
  - External service calls
  - Operations with names suggesting results (`:create`, `:update`, `:delete`, `:register`)
- **Suggest:** Use `GenServer.call` when the caller needs confirmation. Reserve `cast` for true fire-and-forget (metrics, logging, cache warming, notifications where loss is acceptable).
- **Tolerate:**
  - Cast for genuine fire-and-forget (telemetry events, cache updates)
  - Cast in high-throughput scenarios where call overhead is measured and problematic
- **Severity:** `info`

#### 5.14 handle_info Catch-All Must Not Swallow Messages Silently

A catch-all `handle_info(_msg, state)` without logging hides bugs.

- **Why:** Silently discards unexpected messages. If a monitor sends `:DOWN` or a linked process sends `:EXIT` and it's swallowed, you get silent failures. Symptoms appear far from the cause. Since Elixir 1.15+, the default GenServer implementation already logs unexpected messages — omitting the catch-all entirely is correct. (Observability, Fail-Visible)
- **Check:** Flag `handle_info` with wildcard/underscore first argument (`_msg` or `_`) where the function body does not contain `Logger.warning`, `Logger.error`, `Logger.info`, or `require Logger`.
- **Suggest:** Either remove the catch-all entirely (let the default GenServer implementation log it), or add explicit logging:
  ```elixir
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__} unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
  ```
- **Tolerate:**
  - Modules that intentionally discard specific known-irrelevant messages (e.g., SSL info messages)
  - Modules where the catch-all follows specific message handlers
- **Severity:** `info`

#### 5.15 GenServer Timeout Misuse as Polling

Using GenServer timeout as a periodic timer is fragile.

- **Why:** GenServer timeouts reset on ANY incoming message. If any message arrives within the timeout window, the `:timeout` message never fires. This makes it unreliable for periodic work. (Correctness, Silent Failure)
- **Check:** Flag `handle_info(:timeout, ...)` callbacks, especially when timeout values are returned from multiple callback returns in the same module.
- **Suggest:** Use `:timer.send_interval/2` for fixed-interval periodic work, or `Process.send_after/3` for one-shot delayed work:
  ```elixir
  def init(_) do
    :timer.send_interval(5_000, :check_updates)
    {:ok, %{}}
  end
  def handle_info(:check_updates, state) do
    # ... work ...
    {:noreply, state}
  end
  ```
- **Tolerate:**
  - GenServer timeout used as an idle timeout (e.g., hibernate or terminate after inactivity) — this IS the intended use
  - `gen_statem` state timeouts (different semantics — not reset by all events)
- **Severity:** `warning`

#### 5.16 Missing terminate/2 When Holding External Resources

GenServers that acquire external resources (files, sockets, ports) without cleanup in `terminate/2`.

- **Why:** Resources leak on process shutdown. File handles, sockets, and ports are finite OS resources. While BEAM eventually cleans up on process death, orderly cleanup prevents resource exhaustion during restart loops. (Resource Safety)
- **Check:** Flag GenServer modules that call `File.open`, `:gen_tcp.connect`, `:gen_udp.open`, `Port.open`, or NIF resource allocation in `init` or callbacks, but do not define `terminate/2`.
- **Suggest:** Implement `terminate/2` to release resources. Note: `terminate/2` is guaranteed to be called only when the process traps exits or when the supervisor sends a `:shutdown` signal.
- **Tolerate:**
  - Modules where the linked resource is also a process (dies with the GenServer automatically)
  - ETS tables with heir configured
- **Severity:** `info`

### 5D. Process Communication

#### 5.17 Centralized GenServer/Agent Interactions

`GenServer.call/cast` and `Agent.get/update` for a given server should be called only from the module that defines it.

- **Why:** Scattered `GenServer.call(MyServer, {:do_thing, args})` couples callers to the message protocol. Any change to the message format requires updating every call site. The defining module should expose public functions that wrap the calls, providing a stable API. (Information Hiding, Single Responsibility, Official Anti-Pattern: "Scattered Process Interfaces")
- **Check:** Flag:
  - `GenServer.call(LiteralModule, ...)` or `GenServer.cast(LiteralModule, ...)` where `LiteralModule` is not the enclosing module
  - `Agent.get(name, ...)` / `Agent.update(name, ...)` where `name` is a literal and the call is outside the Agent's defining module
- **Suggest:** Add public API functions to the server module:
  ```elixir
  # In MyServer module:
  def do_thing(args), do: GenServer.call(__MODULE__, {:do_thing, args})
  ```
- **Tolerate:**
  - `GenServer.call(pid, ...)` where pid is a variable (dynamic dispatch)
  - `:sys` module calls for debugging
  - Test modules
- **Severity:** `warning`

#### 5.18 No Synchronous Call Chains Between GenServers

GenServer A's callback must not synchronously call GenServer B if B could call back to A.

- **Why:** Direct deadlock if cyclic (A waits for B, B waits for A — both blocked forever). Even non-cyclic deep chains cascade timeouts: if D takes 4s, C times out at 5s, B times out, A times out. The entire chain fails as a unit. (Deadlock, Cascade Failure)
- **Check:** Build a GenServer call graph: for each GenServer module, which other GenServer modules does it call from within callbacks? Detect cycles. Flag chains longer than **2 hops**.
- **Suggest:**
  - Break the chain: have A gather data from B and C independently
  - Use cast + handle_info reply pattern for async communication
  - Use PubSub for fully decoupled communication
  - Return quickly and handle responses in `handle_info`
- **Tolerate:**
  - Short, non-cyclic chains where timeout propagation is explicitly managed
  - Calls to ETS-backed services (not actually blocking a GenServer)
- **Severity:** `warning` (chains > 2), `error` (cycles)

#### 5.19 No Large Messages Between Processes

Sending entire structs, `conn`, or query results to other processes when only a subset is needed.

- **Why:** All data in messages is copied between process heaps (Erlang share-nothing architecture). Sending `conn` copies the request body, assigns, private data, and adapter state. Sending `Repo.all(LargeTable)` copies every row. Anonymous functions in `spawn` capture all referenced variables from the enclosing scope. (Memory, Performance, Erlang Efficiency Guide)
- **Check:**
  - Flag `conn` passed to `spawn`, `Task.async`, `GenServer.call/cast`, `send`
  - Flag `Repo.all(...)` result passed directly to process communication functions
  - Flag large struct types (schemas with many fields) passed directly to spawn/send
- **Suggest:** Extract only needed fields before sending:
  ```elixir
  # Instead of: spawn(fn -> log_request(conn) end)
  ip = conn.remote_ip
  path = conn.request_path
  spawn(fn -> log_request(ip, path) end)
  ```
  For large data, use ETS as shared storage and send only the key.
- **Tolerate:**
  - Small structs explicitly designed for message passing
  - Reference-counted binaries > 64 bytes (shared, not copied)
  - Test code
- **Severity:** `info`

#### 5.20 Process.monitor Without DOWN Handler

Monitoring a process without handling the `:DOWN` message.

- **Why:** The whole point of monitoring is to react to the other process's death. If you don't handle `:DOWN`, the monitor message accumulates in the mailbox and the monitored process's death goes unnoticed. (Incomplete Error Handling)
- **Check:** Flag modules that call `Process.monitor/1` without a corresponding `handle_info({:DOWN, _, :process, _, _}, ...)` clause. Similarly, flag `Process.flag(:trap_exit, true)` without `handle_info({:EXIT, _, _}, ...)`.
- **Suggest:** Add explicit handlers:
  ```elixir
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    Logger.warning("Monitored process #{inspect(pid)} down: #{inspect(reason)}")
    {:noreply, handle_process_death(state, pid)}
  end
  ```
- **Tolerate:**
  - `Task.async` (internally uses monitors with proper handling)
  - Modules where monitor ref is passed to another module that handles the DOWN
- **Severity:** `warning`

#### 5.21 Spawning Without Linking or Monitoring

Using `spawn/1,3` (not `spawn_link` or `spawn_monitor`) in production code.

- **Why:** If the spawned process crashes, the parent has no idea. No error propagation, no cleanup, no retry. The work silently fails. This is "fire-and-forget-and-pray." (Error Invisibility)
- **Check:** Flag `spawn/1` and `spawn/3` (not `spawn_link`, not `spawn_monitor`) in non-test code.
- **Suggest:**
  - Use `spawn_link` if the parent should crash too (fail together)
  - Use `spawn_monitor` if the parent should be notified
  - Best: use `Task.Supervisor.start_child` for supervised fire-and-forget
- **Tolerate:**
  - Benchmark/profiling code
  - Test processes
- **Severity:** `warning`

### 5E. Task Anti-Patterns

#### 5.22 Task.async Without Task.await

`Task.async` return value not passed to `Task.await`, `Task.yield`, or `Task.await_many`.

- **Why:** Official docs: "If you are using async tasks, you must await a reply as they are always sent." The reply message accumulates in the caller's mailbox. The task is linked to the caller — if the task crashes, the caller crashes too. (Resource Leak, Contract Violation)
- **Check:** Track `Task.async` return values through the AST. Flag when the value is not passed to `Task.await`/`Task.yield`/`Task.yield_many`/`Task.await_many`.
- **Suggest:** If you need the result, use `Task.await`. If you don't, use `Task.Supervisor.start_child` instead of `Task.async`.
- **Tolerate:**
  - Return value stored in GenServer state for later await in handle_info
  - Explicit `Process.demonitor(task.ref, [:flush])` pattern
- **Severity:** `warning`

#### 5.23 Tasks Without Task.Supervisor

Using bare `Task.start`, `Task.start_link`, or `Task.async` instead of supervised equivalents.

- **Why:** Official docs: "We encourage developers to rely on supervised tasks as much as possible." Unsupervised tasks lack: crash visibility, graceful shutdown, monitoring, and isolation from the caller. (Supervision, Observability)
- **Check:** Flag `Task.start/1`, `Task.start_link/1`, and `Task.async/1` in non-test production code where no `Task.Supervisor` exists in the application's supervision tree.
- **Suggest:** Add `{Task.Supervisor, name: MyApp.TaskSupervisor}` to your supervision tree, then use:
  ```elixir
  # Fire-and-forget:
  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> work() end)
  # Async with result, isolated from caller:
  Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn -> work() end)
  ```
- **Tolerate:**
  - `Task.async`/`Task.await` pairs in scripts and mix tasks
  - Test code
- **Severity:** `info`

### 5F. Naming and Registry

#### 5.24 No Dynamic Atom Creation for Process Names

Using `String.to_atom` or atom interpolation to construct process names.

- **Why:** Atoms are never garbage collected. With enough unique inputs, the atom table fills up (default limit: 1,048,576) and the VM crashes. This is a well-known denial-of-service vector. (Security, VM Stability, Official Elixir Anti-Patterns)
- **Check:** Flag:
  - `String.to_atom(...)` used in `name:` options or `Process.register`
  - `:"prefix_#{variable}"` atom interpolation for process names
  - `Module.concat` with dynamic inputs for naming
- **Suggest:** Use Registry with `:via` tuples:
  ```elixir
  def start_link(user_id) do
    name = {:via, Registry, {MyApp.Registry, {:session, user_id}}}
    GenServer.start_link(__MODULE__, user_id, name: name)
  end
  ```
- **Tolerate:**
  - `String.to_existing_atom` (only succeeds for already-known atoms)
  - Atom construction from compile-time constants
- **Severity:** `error`

#### 5.25 No Custom Process Registries

GenServer acting as a process registry (storing name-to-pid mappings) instead of using Elixir's built-in Registry.

- **Why:** Reinvents Registry poorly. No automatic cleanup when processes die. Single bottleneck process for all lookups. No partitioning for concurrent access. Registry handles all of this with concurrent reads, automatic deregistration on process death, and optional partitioning. (Reinventing the Wheel, Bottleneck)
- **Check:** Heuristic — flag GenServer modules whose state is primarily pid mappings (Map with pid values), or modules named `*Registry*` that don't use Elixir's `Registry` module.
- **Suggest:** Use `Registry` in the supervision tree:
  ```elixir
  {Registry, keys: :unique, name: MyApp.Registry}
  ```
- **Tolerate:**
  - Distributed registries (Horde, :global) for multi-node scenarios
  - Process groups (`:pg`) for pubsub-style patterns
- **Severity:** `info`

#### 5.26 No Global Registration for Local-Only Processes

Using `:global` registration when the process is only accessed from the local node.

- **Why:** Global registration uses distributed consensus, which is slower and more complex. On a single node, it's pure overhead. Even on multiple nodes, global names create contention and split-brain problems during netsplits. (Performance, Complexity)
- **Check:** Flag `{:global, ...}` in `name:` options and `:global.register_name` calls.
- **Suggest:** Use local `name: __MODULE__` or `{:via, Registry, ...}`. For multi-node, consider `:pg` (process groups) or Horde.
- **Tolerate:**
  - Explicit distributed systems that need cluster-wide singletons
  - Applications documented as multi-node
- **Severity:** `info`

### 5G. ETS Anti-Patterns

#### 5.27 ETS Used as Message Bus

ETS with insert/delete patterns and polling loops to pass data between processes.

- **Why:** Reinvents message passing poorly. No backpressure. Polling wastes CPU. Race conditions between readers. No ordering guarantees. Elixir/Erlang message passing, GenStage, and Broadway exist for exactly this use case. (Wrong Tool)
- **Check:** Heuristic — flag ETS tables with both insert and delete patterns in separate modules, especially combined with `Process.sleep` polling loops and tables named `*queue*` or `*bus*`.
- **Suggest:** Use message passing, GenStage for backpressured producer-consumer, Broadway for data pipelines, or PubSub for fan-out.
- **Tolerate:**
  - ETS used as a bounded buffer with explicit size management
  - ETS used for deduplication (insert-if-absent pattern)
- **Severity:** `info`

#### 5.28 No Heir for Critical ETS Tables

ETS tables owned by a crashable process without `:heir` configured.

- **Why:** When the owning process dies, the ETS table and all data is destroyed. If the supervisor restarts the process, the cache rebuilds from scratch, potentially causing a thundering herd to the backing data source. (Data Loss, Cascading Failure)
- **Check:** Flag `:ets.new` calls without `{:heir, pid, data}` option in GenServer modules.
- **Suggest:** Set the supervisor as heir, or create the ETS table in the supervisor and pass the reference to the child.
- **Tolerate:**
  - Tables that are cheap to rebuild (small, fast data source)
  - Tables created in the Application module's `start/2` (survives child crashes)
  - Tables with `:named_table` owned by a top-level supervisor
- **Severity:** `info`

### 5H. Bottleneck Detection

#### 5.29 Singleton GenServer Bottleneck

Named GenServer handling requests parameterized by entity ID — all entities serialize through one process.

- **Why:** With N concurrent entities, each request queues behind all others. If processing takes 1ms per request, max throughput is 1000 req/sec regardless of available cores. The GenServer becomes the system's ceiling. (Scalability, Amdahl's Law)
- **Check:** Heuristic — flag named GenServers (registered with `name: __MODULE__` or similar) where `handle_call` patterns include an ID-like parameter used to index into map state.
- **Suggest:**
  - Process per entity: `DynamicSupervisor` + `Registry` for lookup
  - ETS for state: no process needed for concurrent reads
  - `PartitionSupervisor` for fixed partitioning across N workers
- **Tolerate:**
  - GenServers that coordinate (not just serve data) — coordination requires serialization
  - Low-throughput systems where bottleneck is theoretical
  - GenServers using ETS internally for the hot path
- **Severity:** `info`

#### 5.30 Process.sleep in Production Code

`Process.sleep` or `:timer.sleep` in non-test code.

- **Why:** Blocks the calling process entirely. In a GenServer, it blocks all message handling. In a Task, it wastes a scheduler thread. For retry logic, it prevents the process from handling other work during the wait. (Blocking, Resource Waste)
- **Check:** Flag `Process.sleep` and `:timer.sleep` in non-test modules.
- **Suggest:** Use `Process.send_after/3` for delayed work, `:timer.send_interval/2` for periodic work:
  ```elixir
  def handle_info({:retry, attempt}, state) do
    case do_thing() do
      {:error, _} when attempt < 3 ->
        Process.send_after(self(), {:retry, attempt + 1}, 1000 * attempt)
        {:noreply, state}
      result ->
        {:noreply, handle_result(state, result)}
    end
  end
  ```
- **Tolerate:**
  - Test modules (waiting for async operations)
  - CLI scripts and mix tasks
  - Explicit backoff in application startup (rare, documented)
- **Severity:** `warning`

#### 5.31 Large State in GenServer

GenServer accumulating unbounded data in its process state.

- **Why:** GenServer state lives on the process heap. Large heaps cause long GC pauses, blocking all message processing. State is copied during garbage collection. State is lost on crash (vs ETS which can survive with heir). Every `handle_call` reply copies data from server heap to caller heap. (Performance, Reliability)
- **Check:** Heuristic — flag GenServer modules where:
  - `Map.put`/`Map.merge` in `handle_cast`/`handle_info` without corresponding cleanup (`Map.delete`/`Map.drop`)
  - Lists grown with `[new | list]` or `list ++ [new]` without size bounds
  - Module name suggests accumulation (`*Cache*`, `*Store*`, `*Buffer*`, `*Accumulator*`)
- **Suggest:** Use ETS for large or growing datasets. Use `:counters` or `:atomics` for numeric state.
- **Tolerate:**
  - GenServers with bounded state (fixed-size maps, ring buffers)
  - State that's periodically flushed or pruned
- **Severity:** `info`

---

## 6. Module Quality

### 6.1 Module Cohesion

Public functions in a module should operate on related data types and concepts.

- **Why:** A module touching HTTP clients, database queries, and email sending has three reasons to change. Split by concern. (SOLID-S, High Cohesion)
- **Check:**
  - Flag modules with more than **20** public functions (warn) or **40** (error)
  - Heuristic: flag modules whose public functions reference 3+ different struct types as primary arguments
  - Flag modules that `alias` more than **10** other modules (high coupling fan-out)
- **Tolerate:**
  - Context facade modules using `defdelegate` (high function count is normal)
  - Enum-like utility modules
  - Test helper/factory modules
  - Schema modules with many fields (inherent complexity)
- **Severity:** `warning` (20+), `error` (40+)

### 6.2 Function Complexity

Individual functions should not be overly complex.

- **Why:** High cyclomatic complexity makes functions hard to understand, test, and maintain. (Cognitive Complexity, already partially covered by Credo but worth including for architectural context)
- **Check:**
  - Function arity > 5: `warning` (use keyword lists, maps, or structs)
  - Cyclomatic complexity > 9: `warning`, > 15: `error`
  - Nesting depth > 3 levels of `case`/`cond`/`if`/`with`: `warning`
- **Tolerate:**
  - Macro definitions (inherently higher complexity)
  - Generated code
  - Complex pattern matching in function heads (this is idiomatic, not complex)
- **Severity:** varies

### 6.3 Struct Field Count

Structs with 32+ fields should be reviewed for decomposition.

- **Why:** At 32 keys, Erlang maps switch from flat to hash-map representation, losing memory optimization. More importantly, large structs suggest mixed concerns. (Performance, Cohesion)
- **Check:** Count fields in `defstruct` calls. Warn at 20, error at 32.
- **Tolerate:**
  - Ecto schemas mapping to wide database tables (sometimes unavoidable)
  - Configuration structs that aggregate settings
  - Structs generated by external schema definitions (protobuf, GraphQL)
- **Severity:** `warning` (20+), `error` (32+)

---

## 7. Test Architecture

### 7.1 Test Structure Mirrors Source Structure

Test files should correspond to source modules, and test functions should test public APIs.

- **Why:** Mirrored structure makes it easy to find tests, identify untested modules, and maintain coverage. Testing private internals creates brittle tests that break on refactoring. (Test Public Behavior, Not Implementation)
- **Check:**
  - Flag source modules in `lib/` that have no corresponding test file in `test/`
  - Flag test files that don't correspond to any source module
  - Flag tests that call functions from `@moduledoc false` modules (testing internals)
- **Tolerate:**
  - Integration test files that test across multiple modules
  - Test support modules (`test/support/`)
  - Protocol implementation modules (tested through the protocol)
  - Internal modules with complex algorithms worth testing directly
  - Thin wrapper modules (e.g., pure `defdelegate`)
- **Severity:** `info`

### 7.2 No Direct Repo Calls in Tests

Tests should set up and verify state through public context APIs, not by reaching directly into the database.

- **Why:** Direct Repo calls in tests bypass business logic (validations, callbacks, side effects). When the context API changes, tests that use Repo directly continue passing while actual usage breaks. (Test Through Public Interfaces)
- **Check:** Flag `Repo.insert`, `Repo.update`, `Repo.delete`, `Repo.all`, `Repo.get` calls in test files outside `test/support/`.
- **Tolerate:**
  - Factory modules in `test/support/` (ExMachina or custom factories)
  - `Ecto.Adapters.SQL.Sandbox` setup
  - Data verification assertions where checking the DB directly is the intent (e.g., verifying cascade deletes)
  - Seeding test data for integration tests
- **Severity:** `info`

### 7.3 Mocks Must Have Behaviour Contracts

Every `Mox.defmock` must reference a behaviour module. Mocking without a behaviour means the mock can drift from the real implementation.

- **Why:** Without a behaviour contract, the mock's function signatures can diverge from reality. Tests pass but production breaks. Behaviours ensure Liskov substitution — every implementation (including mocks) honors the same contract. (SOLID-L)
- **Check:** Flag `Mox.defmock(MockName, for: Module)` where `Module` does not define `@callback` attributes.
- **Tolerate:** None — this is always a design problem.
- **Severity:** `error`

### 7.4 Async Test Eligibility

Test files that don't touch global state should declare `async: true` for parallel execution.

- **Why:** Tests are slow when serial. `use ExUnit.Case, async: true` runs tests across cores. The reasons NOT to be async are well-defined: shared mutable state (Repo without sandbox, named processes, ETS tables, file I/O on shared paths). When none of those apply, async should be the default. Failing to opt in slows the entire suite. (Test Suite Architecture, Performance)
- **Check:** Flag test files using `use ExUnit.Case` or `use *.DataCase` without `async: true` where the test body does not reference: named GenServers/Agents started outside `setup`, `:ets.new`, file system mutation, or `Application.put_env`.
- **Suggest:**
  ```elixir
  use ExUnit.Case, async: true
  ```
- **Tolerate:**
  - Tests that explicitly need serial execution (documented with a comment or `async: false`)
  - Phoenix `ConnCase` that hits the global Endpoint
  - Tests setting `Application.put_env` or modifying the BEAM globally
  - Tests using `start_supervised` for processes with global names
- **Severity:** `info`

### 7.5 No Process.sleep in Tests

Tests using `Process.sleep/1` for synchronization are flaky.

- **Why:** Sleep-based synchronization is wrong for two reasons: it makes tests slow (you wait the full sleep), and it makes tests flaky (the wait is sometimes too short on slow CI). Real synchronization uses messages, monitors, or `assert_receive` with a generous timeout. (Test Reliability)
- **Check:** Flag `Process.sleep/1` and `:timer.sleep/1` in test files.
- **Suggest:** Use `assert_receive`, `Process.monitor` + `assert_receive {:DOWN, ...}`, or `Task.await` with explicit timeouts.
- **Tolerate:**
  - Sleep used to test rate limiting or timeout behaviour itself
  - Comments explaining why sleep is intentional
- **Severity:** `warning`

### 7.6 Test Isolation — No Shared Mutable State

Tests must not depend on order or share mutable state across tests in the same file.

- **Why:** Shared state means tests pass in one order and fail in another. The test suite becomes unreliable, and bugs that only appear under load are masked. Each test should set up its own state via `setup`/`setup_all`. (Test Independence)
- **Check:** Heuristic — flag test files that:
  - Use module attributes (`@`) to store mutable state used across tests
  - Define a process at module level (`@process_name :foo`) and reference it from multiple tests without `setup`
  - Use `Process.put`/`Process.get` for cross-test state
- **Tolerate:**
  - Module attributes for constants (read-only data)
  - `setup_all` for genuinely expensive shared resources
- **Severity:** `info`

### 7.7 Public API Test Coverage

Every public function in a domain module should be tested through the test for that module.

- **Why:** Untested public functions are public-API surface that can silently break. The minimum bar is "every public function is referenced from its corresponding test file." (Test Coverage at Boundaries)
- **Check:** For each module's public functions, verify the corresponding test file references the function name. Flag public functions that appear nowhere in their test file.
- **Suggest:** Add at least one test case per public function. If a function is purely internal, mark it `defp` instead.
- **Tolerate:**
  - Functions tested indirectly through higher-level integration tests (hard to detect — reduce severity for this rule)
  - `defdelegate` (tested at the target)
  - Generated code, callbacks, struct functions
- **Severity:** `info`

### 7.8 Test Naming Convention

Test modules should match their source module's name and follow `_test.exs` convention.

- **Why:** A consistent naming convention makes the test suite navigable. `lib/my_app/accounts.ex` should have `test/my_app/accounts_test.exs` defining `MyApp.AccountsTest`. Mismatches signal that tests have drifted from sources or are testing the wrong thing. (Test Suite Discoverability)
- **Check:**
  - Test files must end in `_test.exs`
  - Test module names must end in `Test`
  - The module name should mirror the source module path
- **Tolerate:**
  - Integration test files with descriptive names (e.g., `signup_flow_test.exs`)
  - Test support modules in `test/support/`
- **Severity:** `info`

---

## 8. Event Sourcing Architecture (when applicable)

These rules apply only when the project uses Commanded or similar event sourcing libraries.

### 8.1 Command/Event Naming Conventions

Commands must use imperative form, events must use past tense.

- **Why:** This naming convention is universal in event sourcing. It distinguishes intent (command) from fact (event) and makes the codebase self-documenting. (Domain-Driven Design, Ubiquitous Language)
- **Check:**
  - Command modules: name should match `Verb + Noun` pattern (e.g., `CreateAccount`, `DepositFunds`)
  - Event modules: name should match `Noun + PastVerb` pattern (e.g., `AccountCreated`, `FundsDeposited`)
- **Tolerate:** Slight naming variations as long as tense is correct
- **Severity:** `warning`

### 8.2 Aggregate Apply Must Be Pure

`apply/2` callbacks in aggregates must not produce side effects.

- **Why:** `apply/2` is called during event replay to rebuild state. Side effects in `apply/2` would fire on every replay, causing duplicate emails, duplicate API calls, etc. All side effects belong in event handlers or process managers. (Event Sourcing Fundamentals)
- **Check:** Flag `apply/2` functions in aggregate modules that contain: `send/2`, `GenServer.call/cast`, `Repo.*`, HTTP client calls, `IO.*`, `Logger.*`, or any function that performs I/O.
- **Tolerate:** None — this is always a bug.
- **Severity:** `error`

### 8.3 Events Must Be Immutable Structs

Events must be defined as structs and must not be modified after creation.

- **Why:** Events are historical facts. Modifying event schemas breaks replay. Use upcasting for schema evolution. (Event Sourcing Law: Event schemas are immutable)
- **Check:**
  - Flag event modules that don't use `defstruct`
  - Flag code that modifies event structs after they're created (e.g., `%{event | field: new_value}` outside of upcasting modules)
- **Tolerate:** Event upcasting modules (their purpose is schema evolution)
- **Severity:** `error`

### 8.4 Projectors Must Not Share Read Models

Each projector should own its read model. No two projectors should write to the same table/schema.

- **Why:** Shared read models create hidden coupling between projectors. Rebuilding one projector corrupts the other's data. (Event Sourcing Law: Different projectors cannot share projections)
- **Check:** Identify Ecto schemas used in projector `project/3` callbacks. Flag schemas referenced by more than one projector.
- **Tolerate:** Shared lookup tables that are truly reference data
- **Severity:** `warning`

---

## 9. State Machine Architecture (when applicable)

These rules apply when using `gen_statem`, `GenStateMachine`, `AshStateMachine`, or `fsmx`.

### 9.1 All States Must Be Reachable

Every defined state must be reachable from an initial state through valid transitions.

- **Why:** Unreachable states are dead code that confuses readers and suggests incomplete refactoring. (State Machine Completeness)
- **Check:** Build a state transition graph from the state machine definition. Run reachability analysis from initial states. Flag unreachable states.
- **Tolerate:** States marked as explicitly deprecated or in-progress development
- **Severity:** `warning`

### 9.2 Terminal States Must Have No Outgoing Transitions

States designated as terminal/final must not define transitions to other states.

- **Why:** Terminal states that transition elsewhere indicate confused state design. Either the state isn't truly terminal, or the transition is a bug. (State Machine Consistency)
- **Check:** Identify terminal states (states with no outgoing transitions or explicitly marked terminal). Flag if they have outgoing transitions.
- **Tolerate:** Self-loops on terminal states (e.g., idempotent retry of cleanup)
- **Severity:** `warning`

### 9.3 No Implicit State via Boolean Flags

Using boolean fields or combinations of fields instead of explicit state machines.

- **Why:** Boolean state fields like `is_active`, `is_verified`, `is_suspended` create an implicit state machine with 2^n possible states, most of which are invalid. An explicit state field makes valid states clear. (Explicit State Machine, Avoid State Explosion)
- **Check:** Heuristic — flag Ecto schemas with 3+ boolean fields whose names suggest state (`is_*`, `has_*`, `*_active`, `*_enabled`, `*_verified`, `*_completed`).
- **Tolerate:**
  - Feature flags (these are configuration, not entity state)
  - Genuinely independent boolean properties
  - Schemas where booleans represent independent capabilities
- **Severity:** `info`

---

## 10. Composition and Extensibility

### 10.1 Prefer Composition Over Deep Inheritance via `use`

Chains of `use` macros that inject behaviour into modules should be shallow.

- **Why:** Deep `use` chains are the functional equivalent of deep inheritance hierarchies. They're hard to understand (what did `use` inject?), hard to override, and create invisible coupling. Prefer explicit `import`/`alias` of what you need, or compose with behaviours. (Composition Over Inheritance adapted for FP)
- **Check:** Flag modules with more than 2 `use` statements (excluding `use ExUnit.Case`, `use GenServer`, and other standard OTP/Phoenix uses).
- **Tolerate:**
  - `use Ecto.Schema` + `use MyApp.Schema` (common pattern for shared schema config)
  - Phoenix/Ash modules that conventionally use multiple macros
  - Test modules with `use ExUnit.Case` + `use MyApp.DataCase`
- **Severity:** `info`

### 10.2 Namespace Depth Limit

Module nesting should not exceed 4 levels.

- **Why:** Excessive nesting suggests over-categorization. It makes `alias` chains long, tab-completion useless, and usually means modules are organized by technical taxonomy rather than domain concepts. (Screaming Architecture, Practical Usability)
- **Check:** Flag modules with more than 4 dots in the name (e.g., `MyApp.Accounts.Users.Queries.Admin` is 4 levels, borderline).
- **Tolerate:**
  - Protocol implementations (`MyApp.Protocols.JSON.MyApp.Accounts.User`)
  - Generated code
  - Ash Framework resource extensions in nested paths
- **Severity:** `info`

---

## Rule Summary Table

### Boundaries & Public API (Sections 1-3)

| # | Rule | Severity | Checkability |
|---|------|----------|-------------|
| 1.1 | Dependency Direction (Hexagonal) | error | Static (AST + graph) |
| 1.1b | Hex Package Layer Respect | warning | Static (AST + mix.exs) |
| 1.2 | Context Encapsulation | warning | Static (AST) |
| 1.3 | No Circular Dependencies | error | Static (graph) |
| 1.4 | No Repo in Interface | warning | Static (AST) |
| 2.1 | Module Documentation | info | Static (AST) |
| 2.2 | Public Specs | warning | Static (AST) |
| 2.3 | No Calls to Private Modules | warning | Static (AST) |
| 3.1 | Duplicated Code (Type-2 clones) | warning | Static (AST hash) |
| 3.2 | No Scattered Config | warning | Heuristic |
| 3.3 | Lib Config via Arguments | warning | Static (AST) |
| 3.4 | Similar Code (Type-3 clones) | info | Static (AST shingles) |
| 3.5 | Reinvented Enumerable | info | Static (AST) |
| 3.6 | No Duplicated Validation | info | Heuristic |

### Abstraction & Coupling Quality (Section 4)

| # | Rule | Severity | Checkability |
|---|------|----------|-------------|
| 4.1 | Behaviour Size | info | Static (count) |
| 4.2 | No Single-Impl Protocols | info | Static (count) |
| 4.3 | No Type-Dispatch Cases | info | Heuristic |
| 4.4 | External Deps Behind Behaviours | warning | Static (AST) |
| 4.5 | Minimal Coupling at Interfaces | warning/info | Static (AST) + Heuristic |
| 4.6 | No Unnecessary Dependencies | info | Static (AST) |

### OTP Process Architecture (Section 5)

| # | Rule | Sub | Severity | Checkability |
|---|------|-----|----------|-------------|
| 5.1 | Supervised Processes | Lifecycle | warning | Static (AST) |
| 5.2 | No Unnecessary Processes | Lifecycle | info | Heuristic |
| 5.3 | Agent Misuse (use ETS) | Lifecycle | info | Heuristic |
| 5.4 | No Flat Supervision Trees | Supervision | info | Static (count) |
| 5.5 | Strategy Matches Coupling | Supervision | info | Heuristic |
| 5.6 | Tune max_restarts | Supervision | info | Static (AST) |
| 5.7 | Restart Type Matches Nature | Supervision | info | Heuristic |
| 5.8 | No Blocking in init/1 | GenServer | warning | Static (AST) |
| 5.9 | No Blocking in Callbacks | GenServer | warning | Static (AST) |
| 5.10 | Pure Callback Logic | GenServer | info | Heuristic |
| 5.11 | No receive in Callbacks | GenServer | error | Static (AST) |
| 5.12 | handle_continue not send(self()) | GenServer | warning | Static (AST) |
| 5.13 | Cast Where Call Needed | GenServer | info | Heuristic |
| 5.14 | No Silent Catch-All | GenServer | info | Static (AST) |
| 5.15 | Timeout Misuse as Polling | GenServer | warning | Static (AST) |
| 5.16 | terminate/2 for Resources | GenServer | info | Static (AST) |
| 5.17 | Centralized Interactions | Communication | warning | Static (AST) |
| 5.18 | No Sync Call Chains | Communication | warning/error | Static (graph) |
| 5.19 | No Large Messages | Communication | info | Heuristic |
| 5.20 | Monitor Without DOWN Handler | Communication | warning | Static (AST) |
| 5.21 | Spawn Without Link/Monitor | Communication | warning | Static (AST) |
| 5.22 | Task.async Without await | Task | warning | Static (AST) |
| 5.23 | Tasks Without Supervisor | Task | info | Static (AST) |
| 5.24 | No Dynamic Atom Names | Naming | error | Static (AST) |
| 5.25 | No Custom Registries | Naming | info | Heuristic |
| 5.26 | No Global for Local | Naming | info | Static (AST) |
| 5.27 | ETS as Message Bus | ETS | info | Heuristic |
| 5.28 | No Heir for Critical ETS | ETS | info | Static (AST) |
| 5.29 | Singleton Bottleneck | Bottleneck | info | Heuristic |
| 5.30 | No Process.sleep in Prod | Bottleneck | warning | Static (AST) |
| 5.31 | Unbounded GenServer State | Bottleneck | info | Heuristic |

### Module Quality, Testing, Architecture-Specific (Sections 6-11)

| # | Rule | Concern | Severity | Checkability |
|---|------|---------|----------|-------------|
| 6.1 | Module Cohesion | Module Quality | warning | Static + Heuristic |
| 6.2 | Function Complexity | Module Quality | warning | Static (AST) |
| 6.3 | Struct Field Count | Module Quality | warning | Static (count) |
| 7.1 | Test Mirrors Source | Testing | info | Static (file system) |
| 7.2 | No Repo in Tests | Testing | info | Static (AST) |
| 7.3 | Mocks Need Behaviours | Testing | error | Static (AST) |
| 8.1 | Command/Event Naming | Event Sourcing | warning | Static (regex) |
| 8.2 | Pure Aggregate Apply | Event Sourcing | error | Static (AST) |
| 8.3 | Immutable Events | Event Sourcing | error | Static (AST) |
| 8.4 | No Shared Projections | Event Sourcing | warning | Static (AST) |
| 9.1 | Reachable States | State Machine | warning | Static (graph) |
| 9.2 | Terminal State Integrity | State Machine | warning | Static (graph) |
| 9.3 | No Implicit Boolean State | State Machine | info | Heuristic |
| 10.1 | Shallow `use` Chains | Composition | info | Static (count) |
| 10.2 | Namespace Depth | Composition | info | Static (count) |
| 11.1 | NIF Behind Behaviour | Native Interop | warning | Static (AST) |
| 11.2 | NIF Scheduler Safety | Native Interop | error | Heuristic |
| 11.3 | NIF Error Isolation | Native Interop | warning | Static (AST) |
| 11.4 | Port/NIF Choice | Native Interop | info | Heuristic |

---

## 11. Native Interop (NIFs, Ports, Rustler, Zigler)

These rules apply when the project uses native code integration — C NIFs, Rust via Rustler, Zig via Zigler, or Ports.

### 11.1 NIFs Must Be Behind a Behaviour Boundary

Native code functions must not be called directly from domain or interface modules.

- **Why:** NIFs are the most dangerous code in a BEAM application — a crash in a NIF takes down the entire VM, not just one process. They're also the hardest to replace and test. Wrapping them behind a behaviour allows: swapping to a pure Elixir fallback, mocking in tests, and isolating the blast radius through a clear API boundary. (Replaceability, Testability, Safety)
- **Check:** Flag direct NIF calls (identified by `use Rustler`, `Zigler`, or `@on_load` with `:erlang.load_nif`) from modules outside the NIF's own namespace. NIFs should be called from their wrapper module, and the wrapper should implement a behaviour.
- **Suggest:** Structure as:
  ```
  lib/my_app/crypto.ex          # Behaviour definition (@callback)
  lib/my_app/crypto/nif.ex      # NIF wrapper (implements behaviour)
  lib/my_app/crypto/fallback.ex  # Pure Elixir fallback (implements behaviour)
  ```
  Select implementation via config: `Application.get_env(:my_app, :crypto_impl, MyApp.Crypto.Nif)`
- **Tolerate:**
  - Rustler NIFs where the generated module IS the public API (Rustler's design encourages this — but the module should still implement a behaviour)
  - Performance-critical paths where an extra function call is measured and problematic (document the exception)
- **Severity:** `warning`

### 11.2 NIFs Must Not Block the BEAM Scheduler

NIF functions must complete within 1ms or use dirty schedulers / yielding.

- **Why:** NIFs run on BEAM scheduler threads. A NIF that takes more than 1ms blocks an entire scheduler, reducing the VM's ability to run other processes. Long-running NIFs cause system-wide latency spikes and can make the VM appear frozen. (VM Stability, Scheduler Fairness)
- **Check:**
  - Flag Rustler NIFs without `#[rustler::nif(schedule = "DirtyCpu")]` or `#[rustler::nif(schedule = "DirtyIo")]` that contain: loops, file I/O, network calls, or calls to libraries known to be slow
  - Flag C NIFs without `enif_schedule_nif` or `ERL_NIF_DIRTY_JOB_CPU_BOUND` for potentially long operations
  - Flag Zigler NIFs without `@nif dirty: :cpu` or `dirty: :io` annotations
  - Heuristic: any NIF that processes variable-size input (images, files, large binaries) likely needs dirty scheduling
- **Suggest:** Use dirty schedulers for any operation that might exceed 1ms:
  ```rust
  #[rustler::nif(schedule = "DirtyCpu")]
  fn heavy_computation(data: Binary) -> NifResult<Binary> { ... }
  ```
  For very long operations (>100ms), consider yielding via `enif_consume_timeslice` or using a Port instead.
- **Tolerate:**
  - NIFs that are provably fast (simple math, small fixed-size operations)
  - NIFs that use `enif_consume_timeslice` for cooperative scheduling
- **Severity:** `error` (for clearly long operations), `warning` (for uncertain duration)

### 11.3 NIF Errors Must Not Crash the VM

NIF code must handle all error cases and return error tuples, never panic or segfault.

- **Why:** Unlike Elixir processes where crashes are isolated, a NIF panic (Rust) or segfault (C) kills the entire BEAM VM — all processes, all connections, everything. Rustler's `NifResult<T>` and `Error` types exist to channel errors safely back to Elixir as `{:error, reason}` tuples. (VM Stability, Let-It-Crash Does Not Apply to NIFs)
- **Check:**
  - Flag Rust NIFs that use `unwrap()`, `expect()`, or `panic!()` — these crash the VM
  - Flag C NIFs without null checks on `enif_*` return values
  - Flag NIF wrapper modules that don't have fallback error handling
  - Flag Rustler NIFs that don't return `NifResult<T>` (returning bare types means panics become VM crashes)
- **Suggest:** Always return `Result`/`NifResult` in Rust NIFs, always check return values in C NIFs:
  ```rust
  #[rustler::nif]
  fn parse(data: Binary) -> NifResult<Term> {
      match internal_parse(&data) {
          Ok(result) => Ok(result.encode(env)),
          Err(e) => Err(Error::Term(Box::new(format!("{}", e)))),
      }
  }
  ```
- **Tolerate:**
  - `unwrap()` on values that are provably never `None`/`Err` (e.g., constant construction)
  - Test-only NIF code
- **Severity:** `warning`

### 11.4 Port vs NIF Decision

Choosing NIF when a Port would provide better safety, or Port when NIF latency is needed.

- **Why:** NIFs share the BEAM's address space — a bug crashes the VM. Ports run as separate OS processes — a bug crashes only the Port. The tradeoff is latency: NIFs have sub-microsecond call overhead, Ports have ~100us overhead per message. Choose based on safety requirements vs latency needs. (Safety vs Performance)
- **Check:** Heuristic — flag:
  - NIFs that call external C libraries not under the project's control (high risk of memory corruption — consider a Port)
  - NIFs that do I/O (network, file) — these should almost always be Ports or use dirty schedulers
  - Ports used for simple CPU-bound transformations with high call frequency (NIF would be more appropriate)
- **Suggest:**
  - **Use NIFs** for: pure computation, data transformation, codec operations, crypto — where latency matters and code is well-controlled
  - **Use Ports** for: interacting with external programs, untrusted C libraries, operations that might hang/crash, long-running processes
  - **Use Rustler** over C NIFs when possible — Rust's memory safety eliminates most VM crash risks
- **Tolerate:**
  - Established, well-tested C libraries used as NIFs (e.g., OpenSSL, libsodium)
  - Architecture choices documented with explicit reasoning
- **Severity:** `info`

---

## Principles Behind the Rules

These rules are derived from established principles, adapted for functional Elixir:

| Principle | Origin | Elixir Manifestation | Rules |
|-----------|--------|---------------------|-------|
| Single Responsibility | SOLID-S | One context per domain; modules don't mix concerns | 1.2, 6.1 |
| Open/Closed | SOLID-O | Behaviours + protocols; new types don't modify existing code | 4.3 |
| Liskov Substitution | SOLID-L | All behaviour implementations honor the same contract/spec | 7.3 |
| Interface Segregation | SOLID-I | Small, focused behaviours; no god-interfaces | 4.1 |
| Dependency Inversion | SOLID-D | Domain defines behaviours; infrastructure implements them | 1.1, 4.4 |
| DRY (selective) | DRY | Same business rule in one place; tolerate incidental duplication across contexts | 3.1, 3.2, 3.6 |
| Pure Core / Impure Shell | Clean Arch | Domain logic is pure; side effects at boundaries; GenServer delegates to pure functions | 5.10 |
| Screaming Architecture | Clean Arch | Namespace reflects domain, not framework | 10.2 |
| Minimal Coupling | ISP + LoD | Interfaces share only what's needed; no struct pass-through, no leaked types | 4.5, 4.6 |
| Composition over Inheritance | GoF adapted | Behaviours + protocols over deep `use` chains | 10.1 |
| Supervision Tree IS Architecture | OTP | Start order = dependency order; strategy encodes coupling; tree expresses failure domains | 5.4-5.7 |
| Error Kernel | OTP | Stable processes near tree root; volatile workers below; design for recovery not prevention | 5.4, 5.5 |
| Let It Crash (for processes) | OTP | Supervised processes crash and restart; error handling via supervision, not defensive code | 5.1, 5.7 |
| Processes for State, Not Organization | OTP | Modules + functions for code structure; processes only for state, concurrency, or isolation | 5.2, 5.3 |
| Centralize Process Interfaces | OTP | GenServer message protocol hidden behind public function API in the defining module | 5.17 |
| Fail Fast | Erlang/OTP | Supervised processes; let it crash; unsupervised = invisible | 5.1, 5.21 |
| Design for Replaceability | Hexagonal | Every external dependency behind a behaviour, including NIFs | 4.4, 11.1 |
| NIF Safety Boundary | BEAM Safety | NIFs can crash the VM; isolate behind behaviours, use dirty schedulers, never panic | 11.1-11.4 |

### What These Rules Do NOT Enforce

- **Specific project structure** — flat, umbrella, and poncho are all valid
- **Specific architecture style** — Phoenix contexts, event sourcing, Ash domains all pass
- **Code formatting** — that's `mix format`
- **Naming style** — that's Credo
- **Type correctness** — that's Dialyzer
- **Security vulnerabilities** — that's Sobelow
- **Performance** — that's benchmarking and profiling

These rules fill the gap: **structural quality, boundary integrity, and test architecture**.
