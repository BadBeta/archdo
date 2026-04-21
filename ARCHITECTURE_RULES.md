# Archdo — Architecture Rules Reference

> **200 rules** across 11 categories. Generated from rule modules.

## 1. Boundaries & Architecture (30 rules)

| Rule | Description |
|------|-------------|
| 1.1 | Dependencies must flow inward (hexagonal architecture) |
| 1.11 | Anemic contexts — contexts too small to justify being a context |
| 1.12 | Untyped boundaries — context public APIs returning map()/keyword() instead of structs |
| 1.14 | Controller/LiveView actions should validate incoming params at the boundary |
| 1.15 | Controller actions with business logic — delegate to context modules |
| 1.16 | LiveView with too many assigns — use streams for collections, reduce socket size |
| 1.17 | LiveView subscribes to PubSub but has no handle_info for broadcasts |
| 1.18 | Module depended on by many others — compile dependency hotspot |
| 1.19 | Function-level circular calls detected via Tarjan's SCC |
| 1.1b | Domain modules must not depend on framework-specific packages |
| 1.2 | External modules must not reach into a context's internal modules |
| 1.20 | Module change has high blast radius — many transitive dependents |
| 1.21 | Function call crosses context boundary — compiled ground-truth |
| 1.22 | Module calls Repo directly instead of through owning context |
| 1.23 | Context boundary quality — cohesion, coupling, and encapsulation analysis |
| 1.24 | Circular context dependencies — Context A depends on Context B which depends on Context A |
| 1.25 | Orphan module — zero incoming and zero outgoing dependencies |
| 1.26 | Domain modules must not reference web layer modules |
| 1.27 | LiveView handle_event contains business logic — delegate to context modules |
| 1.28 | Ecto.Query building in interface layer — queries belong in context modules |
| 1.29 | Schema struct from another context used directly — access through owning context API |
| 1.3 | No circular dependencies between contexts |
| 1.30 | Direct GenServer.call to another context's process — use the context's public API |
| 1.31 | Multiple schemas for the same database table — shared table ownership |
| 1.32 | Module reads another context's Application config keys |
| 1.33 | Multiple contexts access the same named ETS table directly — consider a shared API module |
| 1.4 | No direct Repo access from interface layer |
| 1.5 | Each Ecto schema has one owning context — no cross-context schema construction |
| 1.6 | Cross-cutting concerns (Logger, Telemetry) belong at boundaries, not in domain |
| 1.9 | Time/date should be injectable for testability |

## 10. Composition (2 rules)

| Rule | Description |
|------|-------------|
| 10.1 | Prefer composition over deep `use` chains |
| 10.2 | Module nesting should not exceed 4 levels |

## 11. Native Interop (4 rules)

| Rule | Description |
|------|-------------|
| 11.1 | NIF modules should implement a behaviour for replaceability/testing |
| 11.2 | NIFs processing variable-size input should use dirty schedulers |
| 11.3 | NIF code must not contain panic-inducing patterns |
| 11.4 | Choose Port when safety matters more than NIF latency |

## 2. Public API (2 rules)

| Rule | Description |
|------|-------------|
| 2.1 | Every module must have @moduledoc |
| 2.2 | Public functions in documented modules must have @spec |

## 3. Single Source of Truth (5 rules)

| Rule | Description |
|------|-------------|
| 3.1 | Detect code duplication — Type-2 clones (structurally identical functions) |
| 3.2 | System.get_env should be in config/runtime.exs, not scattered in modules |
| 3.3 | Libraries must accept configuration as arguments, not Application.get_env |
| 3.4 | Detect Type-3 clones — similar functions with minor variations |
| 3.5 | Reinventing iteration patterns instead of using Enum/Stream |

## 4. Coupling & Abstraction (28 rules)

| Rule | Description |
|------|-------------|
| 4.1 | Behaviours should have focused interfaces (max 5 required callbacks) |
| 4.10 | Behaviours with no implementations or only mock implementations |
| 4.11 | Parallel hierarchies — feature additions creating thin files in many directories |
| 4.12 | Primitive obsession — many string params that should be typed structs |
| 4.13 | Mixed concerns — module touching too many distinct concern families |
| 4.14 | Natural seams — public functions cluster by prefix, suggesting sub-modules |
| 4.15 | Custom pubsub/observer reinvention — use Registry or Phoenix.PubSub |
| 4.16 | Multiple *Adapter modules should share a behaviour contract |
| 4.17 | Calls to behaviour/protocol implementations must go through the seam, not directly |
| 4.18 | External calls should have explicit timeouts |
| 4.19 | Context facade modules should have telemetry instrumentation |
| 4.20 | External service calls should not use bang functions in production code |
| 4.21 | Behaviour implementations with no-op stubs suggest the interface should be split |
| 4.22 | Import brings many functions but few are used |
| 4.23 | Module depends on another but uses very few of its exports |
| 4.24 | Protocol implementation missing required functions |
| 4.25 | Internal module (child of a context) called from outside its context |
| 4.26 | Module references another module but never calls any of its functions |
| 4.27 | Alias is declared but the short name is never referenced |
| 4.28 | Repo query inside Enum.map/each/for — classic N+1 pattern |
| 4.29 | Dev/test dependency missing `only:` option — will be included in production releases |
| 4.3 | Type-dispatching case statements suggest missing polymorphism |
| 4.30 | Umbrella child apps with inconsistent dependency options |
| 4.4 | External service calls should go through a behaviour boundary |
| 4.5 | Minimal coupling at module interfaces — import breadth |
| 4.6 | No unnecessary module dependencies |
| 4.7 | Context with too many sub-modules — likely doing too much |
| 4.8 | Mockability — count of direct external IO surfaces vs behaviour seams |

## 5. OTP Process Architecture (43 rules)

| Rule | Description |
|------|-------------|
| 5.1 | All long-running processes must be supervised |
| 5.11 | No receive inside GenServer callbacks |
| 5.12 | Use handle_continue instead of send(self()) in init |
| 5.13 | GenServer.cast used where call is needed |
| 5.14 | handle_info catch-all must not swallow messages silently |
| 5.15 | GenServer timeout misuse as polling mechanism |
| 5.16 | GenServers holding resources should implement terminate/2 |
| 5.17 | GenServer.call/cast should only be used in the defining module |
| 5.18 | No synchronous GenServer.call chains from within callbacks |
| 5.19 | Don't send entire conn or large structs to other processes |
| 5.2 | GenServer used for code organization, not state/concurrency/isolation |
| 5.20 | Process.monitor must have a corresponding :DOWN handler |
| 5.21 | spawn without link or monitor — failures go unnoticed |
| 5.22 | Task.async must be paired with Task.await |
| 5.23 | Tasks should use Task.Supervisor |
| 5.24 | No dynamic atom creation for process names |
| 5.25 | Don't reinvent Registry — use Elixir's built-in Registry module |
| 5.26 | No :global registration for local-only processes |
| 5.27 | ETS used as message bus — use message passing instead |
| 5.28 | Critical ETS tables should configure :heir |
| 5.29 | Named GenServer handling entity-keyed requests — bottleneck risk |
| 5.3 | Agent used as read-heavy cache — ETS would be faster |
| 5.30 | No Process.sleep in production code |
| 5.31 | GenServer accumulating unbounded data in process state |
| 5.32 | Process dictionary (Process.put/get) — hidden state, hard to test |
| 5.33 | GenServer intended as singleton but not registered with a name |
| 5.34 | Unsafe production tracing — :dbg and :erlang.trace have no safety limits |
| 5.35 | GenStage consumer subscription without explicit max_demand/min_demand |
| 5.36 | PIDs stored in state or ETS without monitoring — become stale on process death |
| 5.37 | GenServer without handle_info — unexpected messages pile up in mailbox |
| 5.38 | GenServer.call to self from callback — instant deadlock |
| 5.39 | Process.exit(pid, :kill) bypasses terminate/2 — use :shutdown for graceful stop |
| 5.4 | No flat supervision trees — group related processes |
| 5.40 | ETS table created in GenServer without cleanup in terminate/2 |
| 5.41 | GenServer.call with hardcoded integer timeout — use a named constant |
| 5.42 | Sequential collection processing with I/O — candidate for parallelization |
| 5.43 | GenServer with too many distinct callback message patterns — consider splitting |
| 5.44 | String.to_atom in hot paths risks atom table exhaustion |
| 5.45 | Named ETS tables without cleanup leak on process restart |
| 5.6 | Supervisors should explicitly set max_restarts/max_seconds |
| 5.7 | Restart type must match process lifecycle (permanent/transient/temporary) |
| 5.8 | No blocking work in GenServer init/1 |
| 5.9 | No blocking operations in GenServer callbacks |

## 6. Module Quality (50 rules)

| Rule | Description |
|------|-------------|
| 6.1 | Module cohesion — public function count limit |
| 6.10 | Non-bang functions should return ok/error tuples, not raise |
| 6.11 | Module mixes ok/error tuples with raises, nils, and bare returns |
| 6.12 | Single Responsibility — module has independent function clusters suggesting multiple responsibilities |
| 6.14 | try/rescue used for expected failures — use ok/error tuples or non-bang functions |
| 6.15 | Functions returning ok/error tuples should not call bang functions that can raise |
| 6.16 | System boundary calls (external data, process calls) need rescue/catch, not just ok/error |
| 6.17 | Deeply nested control flow — extract functions to flatten |
| 6.18 | Rescue catches one exception type but raises a different one — hides the original |
| 6.19 | if/else used for structural dispatch — use multi-clause functions or case |
| 6.2 | Function complexity and arity limits |
| 6.20 | Recursive function not in tail position — risks stack overflow on large input |
| 6.21 | Manual recursion over a list — prefer Enum/Stream functions |
| 6.22 | Recursive function appears tail-recursive but TCO is broken by try/rescue or post-call operations |
| 6.23 | Recursive function without depth guard or size limit — stack overflow risk on large input |
| 6.24 | Public function exported but never called — dead code |
| 6.25 | Function only called from dead functions — transitively dead |
| 6.26 | Module exports many functions but few are used externally |
| 6.27 | Public API function has no catch-all clause — crashes on unexpected input |
| 6.28 | Public API function returns inconsistent shapes across clauses |
| 6.29 | Function body is a stub or unimplemented placeholder |
| 6.3 | Struct field count limit |
| 6.30 | Public function always raises or returns a fixed value — likely a stub |
| 6.31 | Function is a pure literal-to-literal mapping — replace with a lookup table |
| 6.32 | try/rescue buried inside anonymous function or callback — extract to named function |
| 6.33 | LLM-generated code slop — unnecessary verbosity, trivial wrappers, redundant patterns |
| 6.34 | Private function is never called within its module |
| 6.35 | Catch-all clause before specific clauses makes later clauses unreachable |
| 6.36 | Redundant guard recheck — type already guaranteed by pattern match or guard |
| 6.38 | Identity transformation — no-op function call that returns its input unchanged |
| 6.39 | Catch-all case clause returns bare nil |
| 6.4 | Module length as architecture signal — long files do too much |
| 6.40 | Verbose ok/error unwrap — case with ok/error that swallows error and returns nil |
| 6.41 | Single-clause `with` should be a `case` instead |
| 6.42 | Conditional with constant/literal condition |
| 6.43 | Public function with 5+ parameters — consider a map, keyword list, or struct |
| 6.44 | Deeply nested control flow — with inside with, or 3+ levels of case/cond/if/with |
| 6.45 | Public function returns bare boolean for failable operation — use {:ok, _}/{:error, reason} |
| 6.46 | String concatenation (<>) in loop — O(n²), use IO lists instead |
| 6.47 | Enum.count/length for empty check — O(n) where O(1) alternatives exist |
| 6.48 | Map.keys/values |> length() — O(n), use map_size/1 which is O(1) |
| 6.49 | Regex literal in hot path — recompiled each call, hoist to module attribute |
| 6.50 | Inefficient list operation — ignores linked-list O(n) characteristics |
| 6.51 | Collection operation has a more efficient alternative |
| 6.52 | String.length/1 used for empty/size check — use byte_size/1 or == "" |
| 6.53 | Keyword.get/fetch inside a loop — Keyword lists are O(n) for lookups |
| 6.6 | Boolean flag arguments — usually two functions glued together |
| 6.7 | Pretentious module names — Manager/Helper/Util/Service hide what the module does |
| 6.8 | Distance from main sequence — concrete/stable or abstract/unstable modules |
| 6.9 | Bare rescue clauses that swallow errors silently |

## 7. Test Architecture (25 rules)

| Rule | Description |
|------|-------------|
| 7.10 | Tests with trivial assertions like assert true, assert 1 == 1 |
| 7.11 | Very large setup blocks suggest over-coupled tests |
| 7.12 | Very large test bodies — likely testing too many things at once |
| 7.13 | Mox setups must call setup :verify_on_exit! to enforce expectations |
| 7.15 | Mock at system boundaries only — don't mock modules you own |
| 7.16 | Use Application.compile_env for dependency injection, not get_env at runtime |
| 7.17 | Test names should be descriptive — not 'it works', 'test 1', etc. |
| 7.18 | Weak assertion — assert function() without pattern match loses error details |
| 7.19 | Test starts processes without on_exit cleanup — causes test pollution |
| 7.2 | Tests should use context APIs, not direct Repo calls |
| 7.20 | Test uses hardcoded real-looking emails, URLs, or API keys |
| 7.21 | Public function only called from test files |
| 7.22 | Test module with many tests but no error-path coverage |
| 7.23 | Tests with excessive mocking — 4+ expect or 3+ stub calls in a single test |
| 7.24 | Empty describe block — contains no test cases |
| 7.25 | Source module has no corresponding test file |
| 7.26 | Processes started in tests without start_supervised! will leak on crash |
| 7.27 | Tests assert on GenServer internal state rather than observable behavior |
| 7.28 | Context facade module has test file but exercises < 30% of public API |
| 7.29 | Test patterns that commonly cause flakiness |
| 7.3 | Every Mox.defmock must reference a behaviour module |
| 7.4 | Test files should declare async: true when eligible |
| 7.5 | No Process.sleep in tests — leads to flaky/slow tests |
| 7.8 | Test modules should be named *Test in *_test.exs files |
| 7.9 | Tests must contain at least one assertion |

## 8. Event Sourcing (8 rules)

| Rule | Description |
|------|-------------|
| 8.1 | Commands use imperative form, events use past tense |
| 8.2 | Aggregate apply/2 must be pure — no side effects |
| 8.3 | Events must be immutable structs |
| 8.4 | Projectors must not share read models |
| 8.5 | Event structs must derive Jason.Encoder for serialization |
| 8.6 | Projectors must not call HTTP/external services or non-deterministic functions |
| 8.7 | Process manager state must come from events, not from projection reads |
| 8.8 | Aggregate modules should `use Commanded.Aggregates.Aggregate` for lifecycle management |

## 9. State Machine (3 rules)

| Rule | Description |
|------|-------------|
| 9.1 | All defined states must be reachable from initial states |
| 9.2 | Terminal states should have no outgoing transitions (except self-loops) |
| 9.3 | No implicit state via boolean flags |

