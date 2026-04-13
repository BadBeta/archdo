# Archdo

Architectural quality checker for Elixir. Catches what Credo (style), Dialyzer (types), and Sobelow (security) miss: structural issues, SOLID violations, OTP anti-patterns, and boundary enforcement.

**125+ rules** across 11 categories. Every finding includes a `why`, ranked fix suggestions, and structured context.

## What it checks

| Category | Examples |
|----------|----------|
| **SOLID principles** | SRP (function clustering), OCP (type dispatch), ISP (no-op stubs), DIP (dependency direction) |
| **Seam integrity** | Calls bypassing behaviour/protocol seams, missing behaviours on adapters/NIFs |
| **OTP discipline** | Blocking callbacks, unsupervised processes, GenServer anti-patterns |
| **Resilience** | External calls without timeouts, bang functions on HTTP clients, missing telemetry |
| **Boundaries** | Circular dependencies, context encapsulation, cross-context write coupling |
| **Duplication** | Type-2/3 function clones, duplicated validation logic |
| **Module quality** | Complexity, cohesion, fan-out, Martin package metrics (Ca/Ce/I/A/D) |
| **Testing** | Mox without behaviours, coverage gaps, test naming, async eligibility |
| **Event sourcing** | Aggregate purity, projection isolation, event immutability |
| **NIF safety** | Panic-inducing patterns, scheduler misuse, missing behaviour wrapping |

## Quick start

### As a Mix dependency

```elixir
# mix.exs
def deps do
  [{:archdo, github: "BadBeta/archdo", only: [:dev, :test], runtime: false}]
end
```

```bash
mix archdo                              # scan lib/
mix archdo --format compact             # one-line-per-finding
mix archdo --paths lib/my_app/accounts  # scan specific paths
mix archdo --only 4.17,6.12             # run specific rules
mix archdo --boundaries                 # cross-module dependency analysis
mix archdo --functions                  # function-level graph analysis
```

### Scan any project without installing

You can also scan external projects from an Archdo checkout:

```bash
cd /path/to/archdo
mix archdo --paths /path/to/other_project/lib --format compact
```

## Using with Claude Code (recommended)

Archdo works best as part of a **two-layer review** with Claude Code and the [Elixir skill](https://github.com/BadBeta/Elixir_skill):

1. **Layer 1 — Archdo** finds structural issues mechanically (fast, exhaustive)
2. **Layer 2 — Elixir skill** provides domain judgment on whether findings are real issues or intentional trade-offs

### Setup

**Step 1: Install the Elixir skill** (gives Claude Code deep Elixir knowledge):

```bash
cd ~/.claude/skills
git clone https://github.com/BadBeta/Elixir_skill.git elixir
```

**Step 2: Clone Archdo** (or add as a dependency to your project):

```bash
git clone https://github.com/BadBeta/archdo.git ~/Projects/Archdo
cd ~/Projects/Archdo && mix deps.get
```

**Step 3: Use it.** Ask Claude Code to review any Elixir project:

> "Check the architecture of /path/to/my_project using Archdo"

Claude will:
1. Run `mix archdo --paths /path/to/my_project/lib` for structural analysis
2. Load the Elixir skill and relevant subskills (OTP, architecture, testing, error handling) to evaluate each finding with deep domain knowledge
3. Present the issues alongside judgment on which matter and how to fix them idiomatically

The Elixir skill's subskills contain the specialized knowledge that makes Layer 2 work — OTP process patterns, architecture decision frameworks, Ecto conventions, error handling idioms, and more. Always use `/elixir` to ensure the skill is loaded before reviewing findings.

### MCP server (optional, for deeper integration)

For projects that want Archdo available as an MCP tool:

```json
// .mcp.json in your project root
{
  "mcpServers": {
    "archdo": {
      "command": "mix",
      "args": ["archdo.mcp"]
    }
  }
}
```

This exposes 5 tools: `archdo_deep_review`, `archdo_analyze_paths`, `archdo_analyze_file`, `archdo_list_rules`, `archdo_explain_rule`.

## Output formats

| Format    | Use for |
|-----------|---------|
| `text`    | Terminal review — grouped, color-coded, full explanations |
| `compact` | grep/CI — one line per finding |
| `json`    | Dashboards, CI integration |
| `llm`     | NDJSON with markdown for LLM consumption |

## Baseline / freeze

Accept existing violations and only flag new ones:

```bash
mix archdo --freeze          # save baseline
git add .archdo_baseline.exs
mix archdo                   # only new violations shown
mix archdo --freeze-stats    # track progress
```

## Documentation

- **[GUIDE.md](GUIDE.md)** — comprehensive user guide
- [ARCHITECTURE_RULES.md](ARCHITECTURE_RULES.md) — all rules documented

## License

MIT.
