# Plan: Diagnostic Rework + MCP Server

**Status:** Phase 4 (docs) complete. ARCHITECTURE_RULES.md now has 3.1=duplicated_code, 3.6=duplicated_validation, plus new sections for 3.4 and 3.5. README rewritten with CLI/format/MCP setup docs. Awaiting user to enable the MCP server in Claude Code via `.mcp.json` or `~/.claude.json` (3.8 integration test).
**Started:** 2026-04-11
**Goal:** Make Archdo usable by any LLM via MCP, with diagnostics that contain enough structured information for an LLM to understand a finding and apply one of several actionable fixes without further context.

This plan spans multiple work sessions. It is **self-contained** — a fresh Claude context with no prior conversation history should be able to read this file end-to-end and pick up exactly where the previous session stopped. Update the **Progress log** at the bottom after every session.

---

## Table of contents

1. [Why this exists](#why-this-exists)
2. [Project context — what Archdo is, how it's built](#project-context)
3. [Decisions already made — DO NOT relitigate](#decisions-already-made)
4. [Glossary](#glossary)
5. [Phase 0 — Diagnostic shape design](#phase-0)
6. [Phase 1 — Foundation: structs, formatters, helpers](#phase-1)
7. [Phase 2 — Rule migration](#phase-2)
8. [Phase 3 — MCP server](#phase-3)
9. [Phase 4 — Polish and release](#phase-4)
10. [Out of scope](#out-of-scope)
11. [Progress log](#progress-log)
12. [Notes for resuming in a fresh context](#resuming)

---

<a id="why-this-exists"></a>
## Why this exists (read first if context is fresh)

Archdo currently emits diagnostics with a single `suggestion` string. That's fine for a human scanning a terminal but too thin for an LLM to act on:

1. The LLM can't tell *why* the finding matters versus what was found.
2. There's no way to express alternative valid fixes — different surrounding code calls for different solutions.
3. There's no machine-readable link back to the canonical rule documentation.

Both deliverables — the new `Diagnostic` shape and the MCP server — depend on this richer structure. The MCP is what exposes Archdo to LLMs (Cursor, Cline, Zed, Codex, Claude Code via MCP, etc.); the elixir skill at `~/.claude/skills/elixir/SKILL.md` already covers preventive architecture knowledge so we are NOT building an `archdo` skill.

---

<a id="project-context"></a>
## Project context

### What Archdo is

Archdo is an architectural quality checker for Elixir. It fills the gap between Credo (style), Dialyzer (types), and Sobelow (security), focusing on:

- Bounded contexts and dependency direction (Hexagonal/Onion architecture)
- OTP process discipline (GenServer, Supervisor, Task, Agent, gen_statem)
- Test architecture (Mox usage, test layout, isolation)
- Code duplication (Type-2 and Type-3 clone detection)
- Function-level call graphs and Martin package metrics (Ca/Ce/I/A/D)
- Event sourcing patterns (Commanded aggregates, projections, process managers)
- NIF and Port discipline

It currently has **111 rules across 11 categories**. It has been validated against ~25 real Elixir projects.

### Project root and directory layout

**Project root:** `/home/vidar/Projects/Archdo`

```
/home/vidar/Projects/Archdo/
├── ARCHITECTURE_RULES.md         # Canonical rule documentation (1368 lines, source of truth for `why` text)
├── DESIGN.md                     # Design notes (268 lines)
├── README.md                     # Brief readme (21 lines)
├── PLAN.md                       # ← this file
├── mix.exs                       # Elixir 1.17, NO deps yet, no OTP application
├── mise.toml                     # Tool versions (run `mix` from project root, not subdirs)
├── .formatter.exs
├── lib/
│   ├── archdo.ex                 # Top-level module: orchestrates phases via Runner
│   ├── archdo/
│   │   ├── ast.ex                # AST helpers: parse_file, find_all, contains?, extract_functions, line, etc.
│   │   ├── config.ex             # Config loading from .archdo.exs / Phoenix conventions
│   │   ├── diagnostic.ex         # ← Phase 1 rewrites this
│   │   ├── formatter.ex          # ← Phase 1 rewrites this
│   │   ├── freeze.ex             # Baseline mechanism for gradual adoption
│   │   ├── function_graph.ex     # Function-level call graph builder
│   │   ├── graph.ex              # Module-level dependency graph
│   │   ├── metrics.ex            # Martin package metrics
│   │   ├── pattern.ex            # AST pattern utilities for clone detection
│   │   ├── rule.ex               # @behaviour Archdo.Rule callback definitions
│   │   ├── runner.ex             # Rule registry + parallel file analysis
│   │   └── rules/                # 111 rule modules grouped by category:
│   │       ├── boundary/         # Section 1: bounded contexts, dependency direction
│   │       ├── composition/      # Section 10: composition over inheritance
│   │       ├── eventsourcing/    # Section 8: Commanded patterns
│   │       ├── module/           # Sections 2, 3, 4, 6: API discipline, DRY, abstraction, quality
│   │       ├── nif/              # Section 11: NIF/Port discipline
│   │       ├── otp/              # Section 5: OTP process architecture (largest category)
│   │       ├── statemachine/     # Section 9: state machine discipline
│   │       └── testing/          # Section 7: test architecture
│   └── mix/
│       └── tasks/
│           └── archdo.ex         # `mix archdo` CLI task — Phase 3 will add `mix archdo.mcp` next to this
└── test/
    ├── archdo_test.exs           # Top-level test
    ├── test_helper.exs
    ├── support/
    │   └── rule_case.ex          # Archdo.RuleCase — test helpers (analyze/3, assert_clean/3, assert_flagged/3)
    └── rules/                    # Mirror of lib/archdo/rules/ — one test file per category (some merged)
        ├── boundary/
        ├── eventsourcing/        # NOTE: most ES rules share event_sourcing_test.exs (single file, multiple describes)
        ├── module/
        ├── nif/
        ├── otp/                  # Mostly one test file per rule, plus more_otp_test.exs for newer rules
        ├── statemachine/
        └── testing/
```

### Core module reference (current state)

These are the files Phase 1 and Phase 3 will touch directly. Read the actual files before editing — they may have evolved since this plan was written.

#### `lib/archdo/diagnostic.ex` — current state (will be replaced in Phase 1)

```elixir
defmodule Archdo.Diagnostic do
  @moduledoc false

  @type severity :: :error | :warning | :info

  @type t :: %__MODULE__{
          rule_id: String.t(),
          severity: severity(),
          message: String.t(),
          suggestion: String.t() | nil,
          file: String.t(),
          line: non_neg_integer()
        }

  @enforce_keys [:rule_id, :severity, :message, :file, :line]
  defstruct [:rule_id, :severity, :message, :suggestion, :file, :line]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
```

#### `lib/archdo/rule.ex` — the behaviour (Phase 3.5 may add optional callbacks)

```elixir
defmodule Archdo.Rule do
  @callback analyze(file :: String.t(), ast :: Macro.t(), opts :: keyword()) ::
              [Archdo.Diagnostic.t()]
  @callback id() :: String.t()
  @callback description() :: String.t()
end
```

Note: graph rules also implement `analyze_graph(graph, config)` but that's not in the behaviour — it's checked via `function_exported?/3` in `Runner.run_graph_rules/3`.

#### `lib/archdo/runner.ex` — rule registry and orchestration

- Module attribute `@phase1_rules` lists ~105 per-file rule modules (lines 6–100)
- Module attribute `@graph_rules` lists 6 cross-file graph rules (lines 102–109)
- `analyze/2` runs only Phase 1 rules in parallel via `Task.async_stream`
- `analyze_with_graph/2` runs Phase 1 then builds the graph and runs `@graph_rules`
- `filter_rules/2` honors `--only` and `--ignore` CLI options
- Timeout per file: 30 seconds (don't change without good reason)

**Key insight for the MCP server (Phase 3):** You call `Archdo.Runner.analyze_with_graph(files, opts)` directly. No CLI parsing, no shell-out. The MCP just needs to convert the returned `[Diagnostic.t()]` to an MCP-friendly map.

#### `lib/archdo/formatter.ex` — current formatters

Three formats today, all writing to stdout:

- `:text` — grouped by category, color-coded severity, includes the `→ suggestion` line
- `:compact` — one line per finding: `file:line: severity [id] message`
- `:json` — hand-rolled JSON via string concatenation (Phase 1 will switch to Jason)

Exit codes:
- `0` — clean
- `1` — warnings present
- `2` — errors present

Phase 1 adds a fourth format `:llm` (NDJSON, one diagnostic per line, full structure including pre-rendered markdown).

#### `lib/archdo/ast.ex` — helpers used by every rule

Most-used functions:
- `parse_file(file)` → `{:ok, ast} | {:error, reason}` — uses `literal_encoder` to wrap literals in `__block__` so line metadata survives
- `extract_module_name(ast)` → `"MyApp.Foo"` (strips `Elixir.` prefix)
- `extract_functions(ast, :public | :private | :all)` → `[{name, arity, meta, args, body}]`
- `find_all(ast, predicate)` → list of matching nodes
- `contains?(ast, predicate)` → boolean
- `line(meta)` → integer (handles `nil` and missing key)
- `test_file?(file)` → boolean

**Recurring AST gotcha:** macro-generated function names produce `name` values that are **not atoms** (e.g., `{:unquote, _, [...]}`). Several rules in this codebase have crashed on this — always guard `Atom.to_string(name)` calls with `is_atom(name)`. See the natural_seams.ex / reinvented_pubsub.ex / port_vs_nif.ex history if you need examples.

#### `lib/archdo/rules/eventsourcing/pure_aggregate_apply.ex` — the smoke-test rule (full source)

This is the rule chosen for the Phase 1 smoke test. Read this current implementation and use it as your before/after reference for the migration:

```elixir
defmodule Archdo.Rules.EventSourcing.PureAggregateApply do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic}

  @impl true
  def id, do: "8.2"

  @impl true
  def description, do: "Aggregate apply/2 must be pure — no side effects"

  @side_effect_patterns [
    {[:GenServer], [:call, :cast]},
    {[:IO], [:puts, :write, :inspect]},
    {[:Logger], [:info, :warning, :error, :debug]},
    {[:File], nil},
    {[:Process], [:send]},
    {[:Repo], nil}
  ]

  @impl true
  def analyze(file, ast, _opts) do
    if not aggregate_module?(ast) do
      []
    else
      find_impure_apply(file, ast)
    end
  end

  defp find_impure_apply(file, ast) do
    fns = AST.extract_functions(ast, :public)

    fns
    |> Enum.filter(fn {name, arity, _, _, _} -> name == :apply and arity == 2 end)
    |> Enum.flat_map(fn {_, _, _meta, _, body} ->
      side_effects = find_side_effects(body)

      Enum.map(side_effects, fn {desc, line} ->
        Diagnostic.new(
          rule_id: id(),
          severity: :error,
          message: "#{desc} in aggregate apply/2 — fires on every event replay",
          suggestion: "apply/2 must be pure state transformation; move side effects to event handlers",
          file: file,
          line: line
        )
      end)
    end)
  end

  # ... find_side_effects, aggregate_module?, has_execute_and_apply? ...
end
```

After Phase 1 migration, the `Diagnostic.new(...)` call should look like Example A in §0.3.

#### `test/support/rule_case.ex` — test helpers (read this before writing tests)

```elixir
defmodule Archdo.RuleCase do
  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: true

      def analyze(rule, code, opts \\ []) do
        file = Keyword.get(opts, :file, "lib/test_module.ex")
        {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true, token_metadata: true)
        rule.analyze(file, ast, opts)
      end

      def assert_clean(rule, code, opts \\ []) do
        diagnostics = analyze(rule, code, opts)
        assert diagnostics == [], "Expected no diagnostics, got: #{inspect(diagnostics)}"
      end

      def assert_flagged(rule, code, opts \\ []) do
        diagnostics = analyze(rule, code, opts)
        assert diagnostics != [], "Expected diagnostics but got none"
        diagnostics
      end
    end
  end
end
```

**Test convention:** existing rule tests typically check `hd(diags).message =~ "some substring"`. After migration these will need updating to check `title`, `message`, OR `why` depending on the assertion intent. Prefer `title` for "did this rule fire" assertions because it's stable; `message` is often parameterized by the file content.

### Build, test, and run commands

**Always run from the project root** (`/home/vidar/Projects/Archdo`). `mise` is configured per-directory and `mix` from a subdirectory will fail with a version error.

```bash
# compile + test
mix compile
mix test
mix test test/rules/eventsourcing/                   # category subset
mix test test/rules/otp/receive_in_callback_test.exs # single file

# run archdo against a target project
mix archdo --paths /path/to/project/lib
mix archdo --paths /path/to/project/lib,test --boundaries
mix archdo --paths /path/to/project/lib --format compact --show-all
mix archdo --paths /path/to/project/lib --format json
mix archdo --only 8.2,5.11 --paths /path/to/project/lib    # subset of rules
```

### Validation projects

These are checked out under `/tmp/elx-errors/` and `/tmp/rw-phoenix/` from prior sessions. After any rule migration, re-run the relevant subset to verify no regressions.

**Error-candidate projects (have real architectural errors):**
- `/tmp/elx-errors/cog` — 280 files, 3× rule 8.3 errors (events as plain maps)
- `/tmp/elx-errors/elixir-node` — 136 files, umbrella, complex AST patterns (good crash-detection target)
- `/tmp/elx-errors/iot_consumer` — 30 files, 1× rule 8.2 error (Logger.error in apply/2) ← **smoke test target**
- `/tmp/elx-errors/simple_pay` — 18 files
- `/tmp/elx-errors/helios_example` — 8 files
- `/tmp/elx-errors/project_73` — 55 files
- `/tmp/elx-errors/trustworthy_bank` — 65 files

**Well-formed validation projects** (used for regression checks): gen_stage, conduit, mjml_nif, moba, segment-challenge, supavisor, trento web, genserver_io, thistle_tea, sequin, req, finch, mint, floki, broadway, claude-hub, marriage_saver, OpenDrive, live_flow, tictactoe — checked out from prior sessions, paths vary.

### `ARCHITECTURE_RULES.md` structure (source of truth for `why` text)

The file is organized by category, with each rule getting an `### N.M Rule Title` heading. Sections are numbered 1–11 matching the rule ID prefixes. When migrating a rule, find its section heading in this file and use it to write the `why` text (and to populate `references: ["ARCHITECTURE_RULES.md#N.M"]`).

Section index (line numbers may have drifted; use grep to relocate):
- §1 Boundary Integrity (line 22)
- §2 Public API Discipline (line 151)
- §3 Single Source of Truth (line 190)
- §4 Abstraction Quality (line 231)
- §5 Process Architecture (OTP) (line 340) — sub-grouped 5A–5H
- §6 Module Quality (line 884)
- §7 Test Architecture (line 931)
- §8 Event Sourcing (line 1044)
- §9 State Machine (line 1090)
- §10 Composition and Extensibility (line 1126)
- §11 Native Interop (line 1245)

---

<a id="decisions-already-made"></a>
## Decisions already made — DO NOT relitigate without explicit user input

| Decision | Choice | Recorded |
|---|---|---|
| Migration scope | **1a** — migrate all 111 rules in one sweep, no back-compat shim | 2026-04-11 |
| MCP runtime | **2a** — Elixir, in-process, calls `Archdo.Runner` directly | 2026-04-11 |
| Skill vs MCP | **No `archdo` Claude Code skill** — elixir skill already covers preventive guidance | 2026-04-11 |
| Phase 0 design | Approved (struct shape, field semantics, worked examples) | 2026-04-11 |
| Rule 3.1 collision | Renumber `duplicated_validation` to `3.6`. `duplicated_code` keeps `3.1` as the canonical DRY rule. | 2026-04-11 |

If you want to revisit any of these, **stop and ask the user first**.

---

<a id="glossary"></a>
## Glossary

A fresh context may not have the prior conversation's vocabulary. Brief definitions of terms used throughout this plan:

- **Aggregate** — Event-sourcing concept: a domain object whose state is rebuilt by replaying events. In Commanded, has `execute/2` (handles commands, returns events) and `apply/2` (handles events, returns new state). `apply/2` MUST be pure because it runs on every replay.
- **Bounded context** — DDD concept: a self-contained subdomain with its own public API. In Phoenix conventions, typically a top-level `lib/myapp/foo/` directory.
- **Diagnostic** — Archdo's structured finding output. The `%Archdo.Diagnostic{}` struct.
- **Event sourcing** — Architecture where state changes are stored as a log of immutable events; current state is derived by replaying them.
- **Fix** (new in Phase 1) — One actionable alternative for resolving a diagnostic. A `%Archdo.Fix{}` struct with `summary`, `detail`, optional `example` and `applies_when`.
- **Graph rule** — A rule that needs the full module dependency graph (e.g., circular dependency detection). Implements `analyze_graph/2` in addition to or instead of `analyze/3`.
- **MCP (Model Context Protocol)** — Anthropic's open protocol for connecting LLMs to tools. JSON-RPC over stdio (or SSE/streamable HTTP). Tools self-describe via `tools/list`. Spec: https://modelcontextprotocol.io
- **Phase 1 rule** — A per-file rule that operates on one AST at a time. Most rules are Phase 1.
- **Process manager** — Commanded concept: a process that subscribes to events and emits new commands, used for cross-aggregate workflows.
- **Projection** — Read model built by subscribing to events and writing to a query store (often Postgres via Ecto).
- **Suggestion** (current) — The single-string fix hint on the old `Diagnostic` struct. Replaced by `alternatives` in Phase 1.
- **Why text** (new in Phase 1) — A 1–3 sentence explanation of the architectural consequence of a finding, separate from the factual `message`.

---

<a id="phase-0"></a>
## Phase 0 — Diagnostic shape design (COMPLETE)

Phase 0 is design only. No code changes. Locked in 2026-04-11 with user approval.

### 0.1 — New struct shape

```elixir
defmodule Archdo.Diagnostic do
  @type severity :: :error | :warning | :info

  @type t :: %__MODULE__{
          rule_id: String.t(),
          severity: severity(),
          title: String.t(),                  # NEW: 3-8 word noun phrase label
          message: String.t(),                # WHAT was found, factual, no advice
          why: String.t(),                    # NEW: WHY it matters — consequence + reasoning
          alternatives: [Archdo.Fix.t()],     # NEW: 1-3 ranked fix options
          references: [String.t()],           # NEW: anchors into ARCHITECTURE_RULES.md, doc URLs
          file: String.t(),
          line: non_neg_integer(),
          context: map()                      # NEW: rule-specific structured detail
        }

  @enforce_keys [:rule_id, :severity, :title, :message, :why, :alternatives, :file, :line]
  defstruct [
    :rule_id, :severity, :title, :message, :why,
    alternatives: [],
    references: [],
    context: %{},
    file: nil,
    line: 0
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)
end

defmodule Archdo.Fix do
  @type t :: %__MODULE__{
          summary: String.t(),                # 1 sentence: what the fix does
          detail: String.t(),                 # 2-5 sentences: how + when to choose this option
          example: String.t() | nil,          # optional before/after snippet (markdown code block)
          applies_when: String.t() | nil      # optional: condition under which this fix is preferred
        }

  @enforce_keys [:summary, :detail]
  defstruct [:summary, :detail, :example, :applies_when]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
```

### 0.2 — Field semantics (the contract)

| Field | Audience | Style | Length |
|---|---|---|---|
| `title` | both | Noun phrase, no verb | 3-8 words |
| `message` | both | Past-tense factual: "X calls Y", "Module Z has N functions sharing prefix" | 1 sentence |
| `why` | LLM primarily | Explains the architectural consequence. NO prescriptions. | 1-3 sentences |
| `alternatives[].summary` | both | Imperative: "Move the side effect to..." | 1 sentence |
| `alternatives[].detail` | LLM primarily | How to apply, when this option fits | 2-5 sentences |
| `alternatives[].example` | LLM primarily | Markdown ` ```elixir ... ``` ` block, before/after if useful | ≤ 20 lines |
| `alternatives[].applies_when` | LLM primarily | "Use this fix when the side effect is purely informational" | 1 sentence, optional |
| `context` | LLM primarily | Rule-specific structured data (e.g. `%{cycle: ["A", "B", "A"]}`, `%{prefix_groups: [...]}`) for richer reasoning | map |
| `references` | both | Anchors like `"ARCHITECTURE_RULES.md#8.2"`, external URLs | list of strings |

### 0.3 — Worked examples (style guide for rule migration)

These are templates rule authors should follow. Living here so future sessions have unambiguous reference cases.

#### Example A — Error severity, two ranked fixes (rule 8.2)

```elixir
%Diagnostic{
  rule_id: "8.2",
  severity: :error,
  title: "Side effect in aggregate apply/2",
  message: "Error.apply/2 calls Logger.error inside an event handler clause",
  why:
    "apply/2 is invoked on every event during aggregate rehydration, not just when the event is first emitted. " <>
    "Side effects there fire N times per process restart, spam observability tooling, and can re-trigger external systems " <>
    "(emails, webhooks, alerts) on every replay.",
  alternatives: [
    %Fix{
      summary: "Move the side effect to the command handler (execute/2)",
      detail:
        "execute/2 runs exactly once per command, before any event is persisted. Emit the log there. " <>
        "apply/2 should be a pure function from (state, event) to new state.",
      example: """
      ```elixir
      # apply/2 stays pure — only updates state
      def apply(error, %ErrorAlerted{} = ev) do
        %Error{error | frequency: error.frequency + 1, status: :alerted}
      end

      # execute/2 emits both the event and the side effect
      def execute(%Error{} = state, %AlertError{} = cmd) do
        Logger.error("\#{cmd.source} exceeded threshold")
        %ErrorAlerted{source: cmd.source}
      end
      ```
      """,
      applies_when: "The side effect should fire when the command is processed, not on replay."
    },
    %Fix{
      summary: "Move the side effect to a process manager subscribed to the event",
      detail:
        "Process managers react to persisted events asynchronously. They run once per emitted event " <>
        "(not once per replay) and are the right place for cross-aggregate workflows or external system calls.",
      applies_when: "The side effect needs to coordinate with other aggregates or external systems."
    }
  ],
  references: ["ARCHITECTURE_RULES.md#8.2", "https://hexdocs.pm/commanded/Commanded.Aggregate.html"],
  context: %{function: "apply/2", side_effect: "Logger.error", line: 87},
  file: "lib/errors/error_aggregate.ex",
  line: 87
}
```

#### Example B — Info severity, three equally-valid fixes (rule 4.7 god context)

```elixir
%Diagnostic{
  rule_id: "4.7",
  severity: :info,
  title: "God context",
  message: "lib/cog/commands has 94 files",
  why:
    "Contexts above ~30 files become hard to navigate, slow CI feedback for small changes, and almost always contain " <>
    "multiple distinct responsibilities that have grown together. The boundary stops being meaningful — touching one " <>
    "feature drags in unrelated context modules.",
  alternatives: [
    %Fix{
      summary: "Split by feature into sibling contexts",
      detail:
        "Group related files by the user-facing capability they implement (e.g., Cog.Commands.Pipeline, Cog.Commands.Auth). " <>
        "Each new context should be self-contained — its own public API, its own internal modules.",
      applies_when: "The 94 files cluster into 3-6 distinct features. Inspect for natural prefix groupings first."
    },
    %Fix{
      summary: "Extract leaf submodules without changing the boundary",
      detail:
        "If files are tightly coupled but the count comes from genuine complexity (not unrelated concerns), keep the " <>
        "context but move helpers into Cog.Commands.Pipeline.* sub-namespaces. This reduces directory clutter without " <>
        "creating new boundary contracts.",
      applies_when: "Files share the same domain but the directory has grown organically without structure."
    },
    %Fix{
      summary: "Accept the size and document the boundary",
      detail:
        "If the context is genuinely cohesive and active development is winding down, document the responsibility " <>
        "in a moduledoc on the public API module and add to the freeze baseline.",
      applies_when: "Splitting would create artificial boundaries with high inter-context coupling."
    }
  ],
  references: ["ARCHITECTURE_RULES.md#4.7"],
  context: %{path: "lib/cog/commands", file_count: 94, threshold: 30},
  file: "lib/cog/commands",
  line: 0
}
```

#### Example C — False-positive prone rule with a "verify first" alternative (rule 1.5 schema ownership)

The first `Fix` should be a verification step, not a code change. This pattern applies whenever a rule has known false-positive modes.

```elixir
alternatives: [
  %Fix{
    summary: "Verify this is actually a cross-context construction",
    detail:
      "Check whether the schema is genuinely owned by another context, or whether the namespace just happens to match. " <>
      "If the construction is inside a test fixture, factory, or seed file, it's intentional and can be ignored.",
    applies_when: "Always do this first."
  },
  %Fix{
    summary: "Use the owning context's public API instead",
    detail: "..."
  }
]
```

### 0.4 — No backwards compatibility

Decision 1a: hard cutover. The old `suggestion` field is removed. Tests that depend on the old shape will break and must be updated as part of each rule's migration. Build is RED from start of Phase 1 until end of Phase 2.

### 0.5 — Phase 0 checkpoint

- [x] User approved §0.1 struct shape (2026-04-11)
- [x] User approved §0.2 field semantics (2026-04-11)
- [x] User reviewed worked examples §0.3 (2026-04-11)
- [x] No code changes — design only

---

<a id="phase-1"></a>
## Phase 1 — Foundation: structs, formatters, helpers

**Goal:** Land the new `Diagnostic` and `Fix` structs, update the formatters, ship a single rule end-to-end as a smoke test. After this phase the build will be RED until Phase 2 completes.

**Files touched in Phase 1:**
- `lib/archdo/diagnostic.ex` (replace)
- `lib/archdo/fix.ex` (create)
- `lib/archdo/formatter.ex` (rewrite)
- `lib/archdo/rules/eventsourcing/pure_aggregate_apply.ex` (smoke-test migration)
- `test/rules/eventsourcing/event_sourcing_test.exs` (update 8.2 test cases)
- `mix.exs` (add `:jason` dep)

### 1.1 — Add the new structs

- [ ] Replace `lib/archdo/diagnostic.ex` with the §0.1 shape (new fields, `@enforce_keys` updated)
- [ ] Create `lib/archdo/fix.ex` with the `Fix` struct (also §0.1)
- [ ] Add convenience builders to `Archdo.Diagnostic` so rules don't need 30-line struct literals each:

  ```elixir
  defmodule Archdo.Diagnostic do
    # ... struct ...
    def error(rule_id, opts), do: build(:error, rule_id, opts)
    def warning(rule_id, opts), do: build(:warning, rule_id, opts)
    def info(rule_id, opts), do: build(:info, rule_id, opts)

    defp build(severity, rule_id, opts) do
      struct!(__MODULE__, [{:rule_id, rule_id}, {:severity, severity} | opts])
    end
  end
  ```

  This means rules can write `Diagnostic.error("8.2", title: ..., message: ..., why: ..., alternatives: [...], file: ..., line: ...)` instead of the full struct literal.

### 1.2 — Update formatters

`lib/archdo/formatter.ex` currently has three formats. Update each, then add a fourth:

- [ ] **`:text`** — print title, message, why (indented), then each alternative as `1. summary` + indented detail. Drop the existing `→` suggestion line. Keep human-readable.
- [ ] **`:compact`** — keep existing structure (`file:line: severity [id] message`) but message becomes `title — message`. Compact format is for grep/scan workflows; do NOT bloat it.
- [ ] **`:json`** — emit the full struct including alternatives, why, references, context. Stop using string concatenation; use `Jason.encode!/1`.
- [ ] **NEW `:llm`** — same data as JSON but pretty-printed and with one diagnostic per object on separate lines (NDJSON), so MCP and CLI consumers can stream. Each diagnostic includes a `markdown` field with a pre-rendered, LLM-friendly markdown block (title as `###`, why as paragraph, alternatives as numbered list with examples). Avoids every consumer having to re-render.

### 1.3 — Add Jason dep

`mix.exs` currently has `defp deps, do: []`. Update to:

```elixir
defp deps do
  [
    {:jason, "~> 1.4"}
  ]
end
```

- [ ] Add the dep
- [ ] Run `mix deps.get`
- [ ] Confirm `mix compile` still works

### 1.4 — Smoke-test rule

Migrate **`Archdo.Rules.EventSourcing.PureAggregateApply` (8.2)** end-to-end. This is the chosen smoke test because:
- We have a real-world detection of it in `iot_consumer/lib/errors/error_aggregate.ex:87`
- It's error-severity (highest stakes)
- It's small (~95 lines)
- The current implementation is in §"Project context" above for reference

Steps:

- [ ] Read `lib/archdo/rules/eventsourcing/pure_aggregate_apply.ex`
- [ ] Read `ARCHITECTURE_RULES.md` §8.2 (around line 1059) for canonical `why` text
- [ ] Rewrite the `Diagnostic.new(...)` call to match Example A in §0.3, using `Diagnostic.error/2` builder
- [ ] Read `test/rules/eventsourcing/event_sourcing_test.exs` and find the `describe "8.2 PureAggregateApply"` block
- [ ] Update tests to assert against `title`/`why`/`alternatives` rather than the old `message =~ "..."` substring matches
- [ ] Run `mix test test/rules/eventsourcing/event_sourcing_test.exs`
- [ ] Run `mix archdo --paths /tmp/elx-errors/iot_consumer/lib --format llm` and inspect the output for rule 8.2 by eye
- [ ] Run all four formats against iot_consumer and confirm each renders correctly:
  - `mix archdo --paths /tmp/elx-errors/iot_consumer/lib --only 8.2 --format text`
  - `mix archdo --paths /tmp/elx-errors/iot_consumer/lib --only 8.2 --format compact`
  - `mix archdo --paths /tmp/elx-errors/iot_consumer/lib --only 8.2 --format json`
  - `mix archdo --paths /tmp/elx-errors/iot_consumer/lib --only 8.2 --format llm`

### 1.5 — Phase 1 checkpoint

- [ ] `mix compile` succeeds
- [ ] `mix test test/rules/eventsourcing/` passes (rest of test suite will be RED — that's expected)
- [ ] Rule 8.2 renders correctly in all four formats against iot_consumer
- [ ] Phase 1 commit message: "diagnostic: new shape with why + alternatives + references"

---

<a id="phase-2"></a>
## Phase 2 — Rule migration (the bulk of the work)

**Goal:** Migrate all 110 remaining rules to the new shape. This phase is grindy but mechanical-with-judgment. Each rule needs at minimum a `title`, `why`, and one `Fix`. Two `Fix` options is the standard target; three for rules where context strongly determines the right answer.

### 2.1 — Migration order

Migrate by category in this order so each session can complete a coherent batch and the test suite gradually goes back to GREEN:

| Order | Category | Rules | Why this order |
|---|---|---|---|
| 1 | (Phase 1 smoke test) | 8.2 | Validates the shape end-to-end |
| 2 | Event Sourcing | 8.1, 8.3–8.8 (7 remaining) | Small, high-error-severity, real test data in iot_consumer/cog/helios |
| 3 | OTP §5A–5C (Lifecycle, Supervision, Internals) | 5.1–5.18 | Largest category — split into 3 batches; do core OTP first |
| 4 | OTP §5D–5H (Communication, Tasks, Naming, ETS, Bottlenecks) | 5.19–5.35 | Rest of OTP |
| 5 | Boundaries | 1.1, 1.1b, 1.2–1.12 (12 rules) | Includes graph rules — verify those work with new shape |
| 6 | Module Quality | 6.1–6.8 | Mix of severities, several false-positive-prone — use Example C pattern |
| 7 | Public API | 2.1–2.3 | Small, straightforward |
| 8 | Single Source of Truth | 3.1–3.5 + 3.6 (renamed from 3.1) | Resolve §2.5 collision in this batch |
| 9 | Coupling & Abstraction | 4.1–4.16 | Largest non-OTP category, lots of metrics rules |
| 10 | Test Architecture | 7.1–7.5, 7.8–7.17 (14 rules) | Several have nuanced "ignore me if intentional" cases |
| 11 | State Machine | 9.1–9.3 | Small |
| 12 | Composition | 10.1–10.2 | Trivial |
| 13 | Native Interop | 11.1–11.4 | Small, all info-severity |

### 2.2 — Per-rule migration steps

For each rule file:

1. **Read** `ARCHITECTURE_RULES.md` for the rule's canonical description (it's the source of truth for `why` and `references`). Find the `### N.M` heading for the rule.
2. **Read** the current rule implementation to understand what it actually detects (sometimes this drifts from the docs).
3. **Read** the existing tests to understand the expected outputs.
4. **Identify** the 1-3 most useful fixes for this rule. Rules of thumb:
   - If there's exactly one correct fix, write one `Fix`
   - If there are multiple valid approaches with different tradeoffs, write 2-3
   - For false-positive-prone rules, the FIRST fix should be "verify this is real" (Example C pattern)
5. **Rewrite** the `Diagnostic.new(...)` call(s) to the new shape using the §1.1 `Diagnostic.error/warning/info` helpers
6. **Populate `context`** with rule-specific structured data — this is what makes the LLM able to reason precisely
7. **Update** the rule's tests
8. **Run** `mix test test/rules/<category>/` for the affected category and confirm green
9. **Mark** the rule complete in the §2.4 checklist below

### 2.3 — Quality bar per rule

A migrated rule passes review only if:
- [ ] `title` reads as a noun phrase (not a verb, not a sentence)
- [ ] `message` is purely descriptive — no "should", "must", "consider"
- [ ] `why` explains the consequence in concrete terms — not "this is bad practice"
- [ ] At least one `Fix` exists
- [ ] Each `Fix.detail` would let an LLM apply the change without re-reading the rule
- [ ] If 2+ fixes exist, each has a meaningfully different `applies_when`
- [ ] `references` includes at least the `ARCHITECTURE_RULES.md` anchor
- [ ] Tests still pass for that rule

### 2.4 — Per-rule checklist (with file paths)

Mark each rule complete with [x] when migrated. File paths are relative to project root (`/home/vidar/Projects/Archdo`).

#### Boundaries (13 rules — note 1.6 and 1.9 live under module/ not boundary/)
- [x] 1.1 — `lib/archdo/rules/boundary/dependency_direction.ex`
- [x] 1.1b — `lib/archdo/rules/boundary/framework_in_domain.ex`
- [x] 1.2 — `lib/archdo/rules/boundary/context_encapsulation.ex`
- [x] 1.3 — `lib/archdo/rules/boundary/circular_dependencies.ex`
- [x] 1.4 — `lib/archdo/rules/boundary/repo_in_interface.ex`
- [x] 1.5 — `lib/archdo/rules/boundary/schema_ownership.ex`
- [x] 1.6 — `lib/archdo/rules/module/cross_cutting_in_domain.ex`
- [x] 1.7 — `lib/archdo/rules/boundary/function_boundary.ex`
- [x] 1.8 — `lib/archdo/rules/boundary/shotgun_surgery.ex`
- [x] 1.9 — `lib/archdo/rules/module/time_injection.ex`
- [x] 1.10 — `lib/archdo/rules/boundary/chatty_boundary.ex`
- [x] 1.11 — `lib/archdo/rules/boundary/anemic_context.ex`
- [x] 1.12 — `lib/archdo/rules/boundary/untyped_boundary.ex`

#### Public API (3 rules)
- [x] 2.1 — `lib/archdo/rules/module/missing_moduledoc.ex`
- [x] 2.2 — `lib/archdo/rules/module/missing_spec.ex`
- [x] 2.3 — `lib/archdo/rules/boundary/private_module_calls.ex`

#### Single Source of Truth (6 rules — includes 3.6 rename)
- [x] 3.1 — `lib/archdo/rules/module/duplicated_code.ex`
- [x] 3.6 — `lib/archdo/rules/module/duplicated_validation.ex` **(renamed from 3.1 → 3.6 during migration)**
- [x] 3.2 — `lib/archdo/rules/module/scattered_config.ex`
- [x] 3.3 — `lib/archdo/rules/module/lib_config_via_args.ex`
- [x] 3.4 — `lib/archdo/rules/module/similar_code.ex`
- [x] 3.5 — `lib/archdo/rules/module/reinvented_enumerable.ex`

#### Coupling & Abstraction (16 rules)
- [x] 4.1 — `lib/archdo/rules/module/behaviour_size.ex`
- [x] 4.2 — `lib/archdo/rules/module/single_impl_protocol.ex`
- [x] 4.3 — `lib/archdo/rules/module/type_dispatch.ex`
- [x] 4.4 — `lib/archdo/rules/module/external_deps_no_behaviour.ex`
- [x] 4.5 — `lib/archdo/rules/boundary/import_breadth.ex`
- [x] 4.6 — `lib/archdo/rules/boundary/unused_dependency.ex`
- [x] 4.7 — `lib/archdo/rules/boundary/god_context.ex`
- [x] 4.8 — `lib/archdo/rules/boundary/mockability.ex`
- [x] 4.9 — `lib/archdo/rules/module/feature_envy.ex`
- [x] 4.10 — `lib/archdo/rules/module/speculative_generality.ex`
- [x] 4.11 — `lib/archdo/rules/boundary/parallel_hierarchies.ex`
- [x] 4.12 — `lib/archdo/rules/module/primitive_obsession.ex`
- [x] 4.13 — `lib/archdo/rules/module/mixed_concerns.ex`
- [x] 4.14 — `lib/archdo/rules/module/natural_seams.ex`
- [x] 4.15 — `lib/archdo/rules/module/reinvented_pubsub.ex`
- [x] 4.16 — `lib/archdo/rules/module/adapters_without_behaviour.ex`

#### OTP §5A–5C — Lifecycle, Supervision, Internals (split into smaller batches if needed)
- [x] 5.1 — `lib/archdo/rules/otp/unsupervised_process.ex`
- [x] 5.2 — `lib/archdo/rules/otp/unnecessary_process.ex`
- [x] 5.3 — `lib/archdo/rules/otp/agent_misuse.ex`
- [x] 5.4 — `lib/archdo/rules/otp/flat_supervision.ex`
- [x] 5.6 — `lib/archdo/rules/otp/max_restarts.ex` (note: 5.5 missing)
- [x] 5.7 — `lib/archdo/rules/otp/restart_type_mismatch.ex`
- [x] 5.8 — `lib/archdo/rules/otp/blocking_init.ex`
- [x] 5.9 — `lib/archdo/rules/otp/blocking_callback.ex`
- [x] 5.11 — `lib/archdo/rules/otp/receive_in_callback.ex` (note: 5.10 missing)
- [x] 5.12 — `lib/archdo/rules/otp/send_self_in_init.ex`
- [x] 5.13 — `lib/archdo/rules/otp/cast_for_call.ex`
- [x] 5.14 — `lib/archdo/rules/otp/silent_catch_all.ex`
- [x] 5.15 — `lib/archdo/rules/otp/timeout_as_polling.ex`
- [x] 5.16 — `lib/archdo/rules/otp/missing_terminate.ex`
- [x] 5.17 — `lib/archdo/rules/otp/scattered_genserver_call.ex`
- [x] 5.18 — `lib/archdo/rules/otp/sync_call_chains.ex`

#### OTP §5D–5H — Communication, Tasks, Naming, ETS, Bottlenecks
- [x] 5.19 — `lib/archdo/rules/otp/large_messages.ex`
- [x] 5.20 — `lib/archdo/rules/otp/monitor_without_handler.ex`
- [x] 5.21 — `lib/archdo/rules/otp/spawn_without_link.ex`
- [x] 5.22 — `lib/archdo/rules/otp/task_async_without_await.ex`
- [x] 5.23 — `lib/archdo/rules/otp/unsupervised_task.ex`
- [x] 5.24 — `lib/archdo/rules/otp/dynamic_atom_name.ex`
- [x] 5.25 — `lib/archdo/rules/otp/custom_registry.ex`
- [x] 5.26 — `lib/archdo/rules/otp/global_registration.ex`
- [x] 5.27 — `lib/archdo/rules/otp/ets_as_bus.ex`
- [x] 5.28 — `lib/archdo/rules/otp/ets_no_heir.ex`
- [x] 5.29 — `lib/archdo/rules/otp/singleton_bottleneck.ex`
- [x] 5.30 — `lib/archdo/rules/otp/process_sleep.ex`
- [x] 5.31 — `lib/archdo/rules/otp/unbounded_state.ex`
- [x] 5.32 — `lib/archdo/rules/otp/process_dictionary.ex`
- [x] 5.33 — `lib/archdo/rules/otp/unnamed_singleton.ex`
- [x] 5.34 — `lib/archdo/rules/otp/unsafe_tracing.ex`
- [x] 5.35 — `lib/archdo/rules/otp/genstage_no_demand.ex`

#### Module Quality (8 rules)
- [x] 6.1 — `lib/archdo/rules/module/module_cohesion.ex`
- [x] 6.2 — `lib/archdo/rules/module/function_complexity.ex`
- [x] 6.3 — `lib/archdo/rules/module/struct_field_count.ex`
- [x] 6.4 — `lib/archdo/rules/module/module_length.ex`
- [x] 6.5 — `lib/archdo/rules/module/function_fan_out.ex`
- [x] 6.6 — `lib/archdo/rules/module/boolean_flag_args.ex`
- [x] 6.7 — `lib/archdo/rules/module/pretentious_name.ex`
- [x] 6.8 — `lib/archdo/rules/module/main_sequence_distance.ex`

#### Test Architecture (14 rules — note 7.6, 7.7 missing)
- [x] 7.1 — `lib/archdo/rules/testing/test_mirrors_source.ex`
- [x] 7.2 — `lib/archdo/rules/testing/repo_in_tests.ex`
- [x] 7.3 — `lib/archdo/rules/testing/mocks_need_behaviours.ex`
- [x] 7.4 — `lib/archdo/rules/testing/async_eligibility.ex`
- [x] 7.5 — `lib/archdo/rules/testing/sleep_in_tests.ex`
- [x] 7.8 — `lib/archdo/rules/testing/test_naming.ex`
- [x] 7.9 — `lib/archdo/rules/testing/no_assertion.ex`
- [x] 7.10 — `lib/archdo/rules/testing/trivial_assertion.ex`
- [x] 7.11 — `lib/archdo/rules/testing/long_setup.ex`
- [x] 7.12 — `lib/archdo/rules/testing/long_test.ex`
- [x] 7.13 — `lib/archdo/rules/testing/mocks_not_verified.ex`
- [x] 7.14 — `lib/archdo/rules/testing/coverage_gap.ex`
- [x] 7.15 — `lib/archdo/rules/testing/mocking_own_modules.ex`
- [x] 7.16 — `lib/archdo/rules/testing/runtime_config_for_di.ex`
- [x] 7.17 — `lib/archdo/rules/testing/generic_test_names.ex`

#### Event Sourcing (8 rules)
- [x] 8.2 — `lib/archdo/rules/eventsourcing/pure_aggregate_apply.ex` (Phase 1 smoke test)
- [x] 8.1 — `lib/archdo/rules/eventsourcing/command_event_naming.ex`
- [x] 8.3 — `lib/archdo/rules/eventsourcing/immutable_events.ex`
- [x] 8.4 — `lib/archdo/rules/eventsourcing/shared_projections.ex`
- [x] 8.5 — `lib/archdo/rules/eventsourcing/events_need_jason_encoder.ex`
- [x] 8.6 — `lib/archdo/rules/eventsourcing/projector_reads_external.ex`
- [x] 8.7 — `lib/archdo/rules/eventsourcing/process_manager_reads_projection.ex`
- [x] 8.8 — `lib/archdo/rules/eventsourcing/aggregate_missing_behaviour.ex`

#### State Machine (3 rules)
- [x] 9.1 — `lib/archdo/rules/statemachine/state_reachability.ex`
- [x] 9.2 — `lib/archdo/rules/statemachine/terminal_state_integrity.ex`
- [x] 9.3 — `lib/archdo/rules/statemachine/implicit_boolean_state.ex`

#### Composition (2 rules)
- [x] 10.1 — `lib/archdo/rules/composition/shallow_use.ex`
- [x] 10.2 — `lib/archdo/rules/composition/namespace_depth.ex`

#### Native Interop (4 rules)
- [x] 11.1 — `lib/archdo/rules/nif/nif_behind_behaviour.ex`
- [x] 11.2 — `lib/archdo/rules/nif/nif_scheduler_safety.ex`
- [x] 11.3 — `lib/archdo/rules/nif/nif_panic.ex`
- [x] 11.4 — `lib/archdo/rules/nif/port_vs_nif.ex`

**Total: 110 remaining + 1 done (8.2) = 111 rules**

### 2.5 — Known issues to resolve during migration

- **Rule 3.1 collision** — DECIDED: rename `duplicated_validation` to 3.6. Action items during the SSoT batch:
  - [ ] Change `def id, do: "3.1"` → `def id, do: "3.6"` in `lib/archdo/rules/module/duplicated_validation.ex`
  - [ ] Update any test that references "3.1" for duplicated_validation
  - [ ] Update `ARCHITECTURE_RULES.md` §3 to renumber the validation rule heading from 3.1 to 3.6 (and renumber 3.2–3.5 if they were originally pre-shifted, double-check)

- **Missing rule IDs** — Several gaps in numbering: 5.5, 5.10, 7.6, 7.7. These may be deliberately reserved (e.g., 7.6 "Test Isolation" and 7.7 "Public API Test Coverage" appear in ARCHITECTURE_RULES.md but have no rule file). Check whether they're documented but unimplemented (intentional) or accidents.
  - [ ] Audit gaps and record decisions here:
    - 5.5: ____
    - 5.10: ____
    - 7.6: ____
    - 7.7: ____

### 2.6 — Phase 2 checkpoint

- [ ] All 111 rules migrated
- [ ] `mix test` fully GREEN
- [ ] Re-run all 7 error-candidate projects under `/tmp/elx-errors/` and spot-check 5-10 diagnostics across categories — verify they look good in `--format llm`
- [ ] Run against the well-formed validation projects and confirm no regressions in detection counts
- [ ] Phase 2 commit message: "rules: migrate all 111 rules to new diagnostic shape"

---

<a id="phase-3"></a>
## Phase 3 — MCP server (Elixir, in-process)

**Goal:** Expose Archdo as an MCP server that runs in the same BEAM as the rule engine, with no IPC overhead. Distribute as a Mix task so users can run `mix archdo.mcp` (stdio transport) from any Elixir project that depends on Archdo.

**Files created in Phase 3:**
- `lib/archdo/mcp/server.ex`
- `lib/archdo/mcp/encoder.ex`
- `lib/archdo/mcp/tools/analyze_paths.ex`
- `lib/archdo/mcp/tools/analyze_file.ex`
- `lib/archdo/mcp/tools/list_rules.ex`
- `lib/archdo/mcp/tools/explain_rule.ex`
- `lib/mix/tasks/archdo.mcp.ex`
- (maybe) update `lib/archdo/rule.ex` — add optional `long_description/0`, `examples/0`, `references/0` callbacks
- update `mix.exs` — add MCP library dep
- update `README.md` — document MCP setup

### 3.1 — Library choice

Two viable Elixir MCP libraries (verify current state at start of phase — both moved fast in 2025):

- **`hermes_mcp`** — full server + client framework, supports stdio + SSE + streamable HTTP transports, has a `defcomponent`-style DSL for tools. Most likely fit.
- **`anubis_mcp` / `mcp_elixir`** — alternatives, smaller surface area.

- [ ] Spike: try Hermes first. If frontmatter or API churn makes it painful, fall back to writing a minimal stdio MCP server by hand (the MCP protocol is JSON-RPC over stdio — small enough to implement directly if needed).
- [ ] Add chosen lib to `mix.exs`

### 3.2 — Server module structure

```
lib/archdo/mcp/
├── server.ex            # MCP server entry point, transport setup
├── tools/
│   ├── analyze_paths.ex
│   ├── analyze_file.ex
│   ├── list_rules.ex
│   └── explain_rule.ex
└── encoder.ex           # Diagnostic -> MCP-safe map conversion
```

### 3.3 — Tools to expose

| Tool name | Args | Returns | Notes |
|---|---|---|---|
| `archdo_analyze_paths` | `paths: [string], opts: {only?, ignore?, severity?}` | `%{summary: ..., diagnostics: [...]}` | Wraps `Runner.analyze_with_graph/2`. |
| `archdo_analyze_file` | `file: string, content: string, opts: {...}` | Same shape | Lets the LLM check code it just wrote, before saving. Parses `content` directly via `Code.string_to_quoted/2` (may need a new `AST.parse_string/2` helper that mirrors `parse_file/1`'s options). |
| `archdo_list_rules` | `category?: string` | List of `{id, title, severity, description, category}` | Discovery — helps the LLM know what's checked. |
| `archdo_explain_rule` | `id: string` | `{id, title, description, why, examples, references}` | Returns the canonical long-form rule documentation. |

### 3.4 — Tool input/output schemas

Each MCP tool needs a JSON Schema describing its input. Sketch for `archdo_analyze_paths`:

```elixir
input_schema do
  field :paths, {:list, :string}, required: true,
    description: "List of directory or file paths relative to the project root."
  field :only, {:list, :string},
    description: "Restrict to these rule IDs (e.g. [\"5.11\", \"8.2\"])."
  field :ignore, {:list, :string},
    description: "Skip these rule IDs."
  field :min_severity, :string, enum: ~w(info warning error),
    description: "Filter out diagnostics below this severity. Default: info."
end
```

Output is always:

```elixir
%{
  summary: %{errors: 1, warnings: 12, infos: 47, total: 60},
  diagnostics: [...]   # each in the §0.1 shape
}
```

The summary lets the LLM decide whether to drill in or move on without iterating the list.

### 3.5 — Rule registry for `explain_rule`

`ARCHITECTURE_RULES.md` is 1368 lines of human-readable markdown. Two options:

- **(a)** Parse it on demand — slow, brittle to format changes
- **(b)** Build a compile-time registry — each rule module gets new optional callbacks `long_description/0`, `examples/0`, `references/0` and the registry is built from the rule module list

**Recommendation: (b)**. Slot this work into Phase 2 — for each rule being migrated, also fill out the long-form fields. This way Phase 2 produces both the new diagnostics AND the explain_rule data, with no separate parser pass.

- [ ] Add optional callbacks to `Archdo.Rule` behaviour
- [ ] Update each rule during Phase 2 migration
- [ ] `Archdo.Mcp.Tools.ExplainRule` reads from rule modules directly via the runner's `@phase1_rules` and `@graph_rules` lists

### 3.6 — Mix task entry point

`lib/mix/tasks/archdo.mcp.ex`:

```elixir
defmodule Mix.Tasks.Archdo.Mcp do
  use Mix.Task
  @shortdoc "Run Archdo as an MCP server over stdio"

  def run(_args) do
    Mix.Task.run("app.start")
    Archdo.Mcp.Server.start_link(transport: :stdio)
    Process.sleep(:infinity)
  end
end
```

- [ ] Implement the task
- [ ] Document invocation in README

### 3.7 — Manual MCP testing

- [ ] Use `mcp inspector` (the official MCP debugging tool) to connect to `mix archdo.mcp` and verify all four tools list correctly
- [ ] Call `archdo_analyze_paths` on `iot_consumer` and confirm the structured diagnostic for rule 8.2 round-trips intact
- [ ] Call `archdo_analyze_file` with a synthetic snippet and confirm in-memory parsing works
- [ ] Call `archdo_list_rules` and confirm all 111 rules are listed
- [ ] Call `archdo_explain_rule` for a few IDs across categories

### 3.8 — Claude Code integration test

- [ ] Add the MCP server to `~/.claude/mcp.json` (or equivalent) pointing at `mix archdo.mcp` in the Archdo dir
- [ ] In a fresh Claude Code session, ask Claude to "check the architecture of /tmp/elx-errors/iot_consumer with archdo" and verify it invokes the tool, parses the response, and surfaces the rule 8.2 finding with actionable fixes

### 3.9 — Phase 3 checkpoint

- [ ] MCP server compiles and starts
- [ ] All four tools work via mcp-inspector
- [ ] Claude Code integration test passes
- [ ] README updated with MCP setup instructions
- [ ] Phase 3 commit message: "mcp: in-process Elixir MCP server exposing analyze/list/explain tools"

---

<a id="phase-4"></a>
## Phase 4 — Polish and release

- [ ] Add a `mix archdo.mcp.test` task that runs the server against a fixture project for CI
- [ ] Document the new diagnostic shape in `DESIGN.md`
- [ ] Add a section to `README.md` explaining MCP usage
- [ ] Tag a release if Archdo is published

---

<a id="out-of-scope"></a>
## Out of scope (DO NOT do these unless explicitly requested)

- Building a Claude Code skill for Archdo (the elixir skill covers it)
- Building a Node/TypeScript MCP server (decision 2a)
- Backwards compatibility shim for old `suggestion` field (decision 1a)
- Adding new rules — this plan is shape work only, not detection work
- Refactoring the runner, graph, or AST modules (touch only what's needed for the new shape)
- Web UI, dashboards, IDE plugins
- Changing the freeze/baseline mechanism
- Migrating to an OTP application (currently not one — `application/0` returns just `extra_applications: [:logger]`)

---

<a id="progress-log"></a>
## Progress log

Update this section after each session. Format: `YYYY-MM-DD — phase.section — what was done — what's next`.

| Date | Phase | What was done | Next session should... |
|---|---|---|---|
| 2026-04-11 | — | Plan written. Phase 0 ready for review. | Get user approval on Phase 0 §0.1 + §0.2, then start Phase 1 |
| 2026-04-11 | 0 | Phase 0 approved. Rule 3.1 collision resolved (rename `duplicated_validation` to 3.6). | Start Phase 1.1: replace `Diagnostic`, add `Fix`, helper builders |
| 2026-04-11 | — | Plan rewritten with full project context, file paths, glossary, current code refs | Start Phase 1.1 |
| 2026-04-11 | 1 | Phase 1 done. New `Diagnostic` shape + `Fix` struct + builders shipped. Formatters rewritten (text/compact/json/llm). `:jason` added. Rule 8.2 migrated end-to-end and validated against `iot_consumer/lib/errors/error_aggregate.ex:87` in all four formats. Tests for 8.2 updated and passing. | Start Phase 2: migrate remaining 7 event-sourcing rules (8.1, 8.3–8.8) per §2.4 — they're the same category and have real test data. Build is RED for all other rules (decision 1a) until Phase 2 completes. |
| 2026-04-11 | 2 | Phase 2 progress: Event Sourcing batch (8.1, 8.3–8.8) and **all OTP rules** (5.1–5.4, 5.6–5.9, 5.11–5.35 — 33 rules) migrated. ES + OTP test suites are GREEN (53 tests). Pattern established: replace `Diagnostic.new` with `Diagnostic.error/warning/info/2` builders, add `title`/`why`/`alternatives: [Fix.new(...)]`/`references: ["ARCHITECTURE_RULES.md#X.Y"]`/`context: %{...}`. Tests assert against `title` + `context` rather than message substrings. Also fixed several `Module.concat(parts) \|> to_string` "Elixir." prefix leaks by switching to `Enum.join(parts, ".")`. **41/111 rules done.** | Continue Phase 2 with Boundaries batch (13 rules: 1.1, 1.1b, 1.2–1.12 — note 1.6 lives at `lib/archdo/rules/module/cross_cutting_in_domain.ex` and 1.9 at `module/time_injection.ex`). Boundaries includes the graph rules (1.1, 1.3) — verify those still work with the new shape. |
| 2026-04-11 | 2 | **Phase 2 COMPLETE.** All 111 rules migrated. Boundaries (13), Public API (3), SSoT (6 — incl. 3.1 → 3.6 rename of duplicated_validation), Coupling & Abstraction (16), Module Quality (8), Test Architecture (14), State Machine (3), Composition (2), Native Interop (4). **Full test suite GREEN: 118 tests, 0 failures.** Rule 3.1 is now `duplicated_code`; `duplicated_validation` is renumbered to 3.6. Note: ARCHITECTURE_RULES.md hasn't been updated for the rename — do this at the start of Phase 4 polish. | Start Phase 3: MCP server. Pick a library (try Hermes first per §3.1), implement `Archdo.Mcp.Server` and the four tools (analyze_paths/analyze_file/list_rules/explain_rule), wire up `mix archdo.mcp` task, test via mcp-inspector and a real Claude Code session against `/tmp/elx-errors/iot_consumer`. |
| 2026-04-12 | 3 | **Phase 3 functionally complete.** Skipped Hermes/Anubis libraries — hand-rolled a minimal stdio MCP server in `lib/archdo/mcp/server.ex` (newline-delimited JSON-RPC 2.0 over stdin/stdout, ~150 lines). Tools: `archdo_analyze_paths` (wraps `Runner.analyze_with_graph`), `archdo_analyze_file` (in-memory parsing via `Code.string_to_quoted/2`), `archdo_list_rules` (with category filter), `archdo_explain_rule`. Each tool returns both `content` (text) and `structuredContent` (parsed map). Mix task at `lib/mix/tasks/archdo.mcp.ex` boots the server. Added `Archdo.Runner.phase1_rules/0` and `graph_rules/0` so tools can enumerate without poking module attributes. Smoke-tested all four tools end-to-end against `/tmp/elx-errors/iot_consumer/lib/errors/error_aggregate.ex:87` and confirmed full diagnostic shape (title/why/alternatives/references/context) round-trips intact. Suite still GREEN at 118/118. | Phase 3.8 (Claude Code integration test) and Phase 4 polish: (1) wire the MCP server into a Claude Code session via `~/.claude/mcp.json` and verify Claude calls it, (2) update ARCHITECTURE_RULES.md for the 3.1 → 3.6 rename, (3) document MCP setup in README.md, (4) consider an `archdo.mcp.test` mix task for CI fixture verification. |
| 2026-04-12 | 4 | **Phase 4 docs complete.** Updated `ARCHITECTURE_RULES.md`: §3.1 is now `Duplicated Code (Type-2 clones)`, §3.4 added (`Similar Code / Type-3 clones`), §3.5 added (`Reinvented Enumerable`), §3.6 is the renumbered `No Duplicated Validation Logic`. Rule summary table updated. History note added explaining the 3.1 → 3.6 rename. Rewrote `README.md` from the placeholder stub: now covers the project goal, the 11 categories, CLI usage, all four output formats including `:llm`, the freeze/baseline workflow, and a full MCP setup section with `.mcp.json` snippets for Claude Code/Cursor/Cline/Zed. Suite still GREEN at 118/118. | (Optional) Have the user enable the MCP server in Claude Code (project-local `.mcp.json` in this repo, or globally in `~/.claude.json`) and verify Claude can drive `archdo_analyze_paths` against a real project. After that, only Phase 4.4 remains (optional `archdo.mcp.test` mix task for CI). |

---

<a id="resuming"></a>
## Notes for resuming in a fresh context

If this is your first time picking up this plan:

1. **Read the §"Why this exists" section and the §"Decisions already made" table** — do not relitigate them.
2. **Read §"Project context"** to understand what Archdo is, where files live, and what each module does. The "Core module reference" subsection has the actual current source of `Diagnostic`, `Rule`, the smoke-test rule, and `RuleCase` so you can compare old vs new without re-reading the codebase.
3. **Find the most recent row in §"Progress log"**. That tells you the current phase and what to do next.
4. **If you're in Phase 2**, find the next unchecked rule in §2.4 and follow §2.2 for it. The per-session sweet spot is **8–15 rules with full test coverage** — pick a category boundary if possible so the test suite goes back to GREEN at end of session.
5. **The `Archdo.Diagnostic` and `Archdo.Fix` definitions in §0.1 are the contract** — if you're tempted to change them, STOP and check with the user. Changing the shape mid-migration multiplies the work.
6. **The worked examples in §0.3 are your style guide.** When in doubt about how to phrase a `why` or how many `Fix` options to write, look at Example A/B/C.
7. **Use `Archdo.Diagnostic.error/2`, `.warning/2`, `.info/2` builders** (added in Phase 1.1) — not full struct literals.
8. **Always run `mix` from `/home/vidar/Projects/Archdo`** — `mise` is per-directory and `mix` from a subdir errors out.
9. **Update §"Progress log" before ending the session** with what got done and what's next.
10. **If you hit a non-atom function name crash** (`{:unquote, _, [...]}`-style), fix it with an `is_atom(name)` guard — there's a history of these in this codebase under natural_seams.ex / reinvented_pubsub.ex / port_vs_nif.ex.
