# Archdo — Comprehensive User Guide

> **Audience.** This guide is written to be useful for both humans and LLM agents (Claude Code, Cursor, Cline, Zed, Codex). LLMs reading it as context should treat the rule descriptions, diagnostic schema, and tool contracts as authoritative.

---

## Table of contents

1. [What Archdo is and why](#1-what-archdo-is-and-why)
2. [Installation](#2-installation)
3. [The 193 rules at a glance](#3-the-193-rules-at-a-glance)
4. [The diagnostic shape](#4-the-diagnostic-shape)
5. [Output formats](#5-output-formats)
6. [CLI reference](#6-cli-reference)
7. [Configuration (`.archdo.exs`)](#7-configuration-archdoexs)
8. [Freeze / baseline workflow](#8-freeze--baseline-workflow)
9. [MCP server (for LLM clients)](#9-mcp-server-for-llm-clients)
10. [Architecture (how Archdo works internally)](#10-architecture-how-archdo-works-internally)
11. [Guidance for LLM clients](#11-guidance-for-llm-clients)
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
| **Archdo**   | Boundaries, OTP, test architecture, duplication, event sourcing, NIF discipline, Martin metrics | Style, types, security |

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

## 3. The 193 rules at a glance

Archdo currently ships **193 rules in 11 categories** (including 21 compiled-analysis rules, 8 performance rules, and 5 LLM slop detectors). Full text for every rule is in [ARCHITECTURE_RULES.md](ARCHITECTURE_RULES.md).

| #   | Category                         | Rules    | Severity mix          | What it catches                                                                  |
|-----|----------------------------------|----------|-----------------------|----------------------------------------------------------------------------------|
| 1   | Boundaries & Architecture        | 24       | error / warning / info | Dependency direction, context encapsulation, circular deps, Repo in interface, schema ownership, function-level boundary leaks, chatty boundaries, anemic contexts, untyped boundaries, unvalidated params, large controller actions, PubSub without handler, large LiveView assigns, unused aliases, **compiled**: compile dependency hotspot, circular function calls, change blast radius, cross-boundary call detection, Repo bypass, circular context deps, orphan modules |
| 2   | Public API                       | 2        | warning / info        | Missing `@moduledoc`, missing `@spec` |
| 3   | Single Source of Truth           | 5        | warning / info        | Type-2 clones, scattered config, library config via `Application.get_env`, Type-3 similar code, reinvented enumerable, duplicated validation across layers |
| 4   | Coupling & Abstraction           | 28       | warning / info        | Behaviour size, single-impl protocols, type-dispatching case, external deps without behaviour, broad imports, unused deps, god contexts, mockability score, feature envy, speculative generality, parallel hierarchies, primitive obsession, mixed concerns, natural seams, hand-rolled pubsub, adapters without behaviour, unbounded external calls, missing telemetry, unprotected bang calls, **compiled**: unused imports, weak dependency, protocol completeness, internal module leak, phantom dependency |
| 5   | OTP Process Architecture         | 43       | error / warning / info | Unsupervised processes, GenServer hygiene, blocking init/callbacks, supervision tree shape, restart strategies, Task discipline, ETS patterns, process-naming safety, bottlenecks, tracing safety, GenStage backpressure, stale PIDs, deadlock detection, missing handle_info, brutal kill, ETS ownership leak, hardcoded timeouts, sequential-where-parallel, **callback sprawl** |
| 6   | Module Quality                   | 50       | error / warning / info | Module cohesion, function complexity & arity, struct field count, file length, function fan-out, boolean flag args, pretentious names, distance from main sequence, error handling (7 rules), nesting depth, if/else dispatch, recursion (4 rules), stub functions, buried try/rescue, **LLM slop detection** (5 sub-checks), dead private functions, unreachable clauses, constant expressions, defensive nil returns, identity transformations, verbose ok/error unwrap, single-clause with, redundant guard rechecks, long parameter lists, nested control flow, boolean blindness, **compiled**: dead code, transitive dead code, API surface weight, non-exhaustive API, inconsistent return shapes, degenerate functions, lookup table candidates |
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

`mix archdo --format <format>` accepts four formats. They're all driven by `Archdo.Formatter` and consume the same `Diagnostic` struct.

### `:text` (default) — for humans at the terminal

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
| `--format`        | enum            | `text` (default) / `compact` / `json` / `llm`                                              |
| `--only`          | comma-separated | Restrict the run to these rule ids: `--only 5.11,8.2`                                      |
| `--ignore`        | comma-separated | Skip these rule ids: `--ignore 6.1,6.4`                                                    |
| `--boundaries`    | flag            | Enable cross-file boundary/graph rules (1.1, 1.3, 1.4, 8.4, etc.). Slower; uses `.archdo.exs`. |
| `--tests`         | flag            | Enable project-level test architecture rules (e.g. test mirrors source, coverage gap).    |
| `--functions`     | flag            | Enable function-level graph analysis (slowest, deepest). Required for 1.7, 1.8, 1.10, 4.9, 6.5. |
| `--coverage`      | flag            | Print test coverage gap matrix and exit (no other rules).                                  |
| `--metrics`       | flag            | Print Martin package metrics (Ca/Ce/I/A/D) matrix and exit.                                |
| `--freeze`        | flag            | Save current findings as the baseline.                                                     |
| `--freeze-stats`  | flag            | Show baseline status (resolved, still present, new).                                       |
| `--show-all`      | flag            | Bypass the baseline filter and show every finding.                                         |

### Common invocations

```bash
# Quick local check (lib/, no boundary rules)
mix archdo

# Full architectural check including cross-file rules
mix archdo --paths lib --boundaries

# Maximum-depth analysis (boundaries + tests + function graph)
mix archdo --paths lib,test --boundaries --tests --functions

# Restrict to one rule (useful for iterating on a specific issue)
mix archdo --only 8.2 --paths lib

# Skip noise from rules you don't care about
mix archdo --ignore 6.1,6.4,7.4

# Pipe machine-readable output to a script
mix archdo --format json > diagnostics.json
mix archdo --format compact | grep error

# LLM-friendly streaming output
mix archdo --format llm > diagnostics.ndjson
```

### Special-purpose commands

```bash
mix archdo --coverage --paths lib    # Test coverage gap matrix only
mix archdo --metrics --paths lib     # Martin Ca/Ce/I/A/D table only
```

These commands skip normal rule output and print a single matrix. Useful as standalone reports.

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
  ]
]
```

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

### The four tools

| Tool name              | Purpose                                                                       | Returns                                                |
|------------------------|-------------------------------------------------------------------------------|--------------------------------------------------------|
| `archdo_analyze_paths` | Run Archdo against directories or files in the project                      | `{summary, diagnostics: [...]}`                         |
| `archdo_analyze_file`  | Analyze an in-memory source string (no file write)                            | `{summary, diagnostics: [...]}`                         |
| `archdo_list_rules`    | List rules (optionally filtered by category)                                  | `{count, rules: [{id, category, description, module}]}` |
| `archdo_explain_rule`  | Look up a rule by id                                                          | `{id, module, description, reference, note}`           |
| `archdo_deep_review`   | Static analysis + structured review plan for the LLM to investigate deeper   | `{diagnostics, review_plan: [...], instructions}`       |

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

Archdo is a small, deterministic, single-process analyzer. There's no daemon, no language server, no compiler hook — just a Mix task that walks the AST.

### High-level pipeline

```
   ┌─────────────┐    ┌──────────────┐    ┌──────────────────┐
   │ collect_files│ → │ parse_file   │ → │ phase1 rules     │
   │ (lib, test)  │    │ (literal_enc)│    │ (per-file)       │
   └─────────────┘    └──────────────┘    └────────┬─────────┘
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
| `Archdo.Formatter`          | The four output formats. Stateless, takes `[Diagnostic.t()]`.               |
| `Archdo.Mcp.Server`         | JSON-RPC 2.0 stdio MCP server with JSV input validation.                    |
| `Archdo.Mcp.SchemaValidator` | Validates tool arguments against `input_schema/0` using JSV.               |
| `Archdo.Mcp.Encoder`        | `Diagnostic` → JSON-friendly map (with MapSet/atom coercion).               |
| `Archdo.Mcp.Tools.*`        | The five MCP tools (each with `name/0`, `description/0`, `input_schema/0`, `call/1`). |
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
    # 1. Decide whether the rule applies to this file at all.
    if not relevant?(ast) do
      []
    else
      # 2. Find offending patterns in the AST.
      offenses = find_offenses(ast)

      # 3. Build a Diagnostic per offense, with full title/why/alternatives.
      Enum.map(offenses, &build_diagnostic(file, &1))
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
| "Do a full architectural review" | `archdo_deep_review` — then **read the files listed in the review plan and answer the questions** |
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
- **Don't run `--boundaries` or `--functions`** unsolicited on huge projects — they're slower. Default to `boundaries: false` in MCP calls unless the user is asking about cross-file architecture.

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

- **[ARCHITECTURE_RULES.md](ARCHITECTURE_RULES.md)** — canonical, exhaustive rule reference. Every rule has its own section with `Why`, `Check`, `Tolerate`, and `Severity`. This is the source of truth that the in-rule `why` text and `alternatives` are derived from.
- **[DESIGN.md](DESIGN.md)** — design rationale and the original three-tier approach. Useful for understanding why Archdo is structured the way it is.
- **[README.md](README.md)** — short intro and installation cheatsheet.
- **[PLAN.md](PLAN.md)** — implementation plan, current phase status, and progress log. Useful for contributors.

---

*This guide is canonical. If anything in it conflicts with another file, fix the other file.*
