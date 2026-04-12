# Archdo

Archdo is an architectural quality checker for Elixir projects. It fills the gap between Credo (style), Dialyzer (types), and Sobelow (security), focusing on the architectural decisions that those tools don't catch:

- Bounded contexts and dependency direction (Hexagonal/Onion architecture)
- OTP process discipline (GenServer, Supervisor, Task, Agent, gen_statem)
- Test architecture (Mox usage, test layout, isolation)
- Code duplication (Type-2 and Type-3 clones)
- Function-level call graphs and Martin package metrics (Ca/Ce/I/A/D)
- Event sourcing patterns (Commanded aggregates, projections, process managers)
- NIF and Port discipline

Archdo currently ships **111 rules across 11 categories**, all documented in [ARCHITECTURE_RULES.md](ARCHITECTURE_RULES.md).

Every diagnostic ships with a `title`, a `why` explanation of the architectural consequence, **ranked actionable fixes** with examples, references back to the canonical rule documentation, and a structured `context` map for tools that want to reason about the finding.

## CLI usage

Install Archdo as a dev dependency in your Elixir project:

```elixir
def deps do
  [
    {:archdo, "~> 0.1.0", only: [:dev, :test], runtime: false}
  ]
end
```

Then run it against your codebase:

```bash
mix archdo                                    # check lib/ in :text format
mix archdo --paths lib,test --boundaries      # also run cross-file boundary rules
mix archdo --only 5.11,8.2 --paths lib        # restrict to specific rules
mix archdo --format compact                   # one-line-per-finding for grep
mix archdo --format json                      # full structured JSON
mix archdo --format llm                       # NDJSON with pre-rendered markdown for LLMs
```

### Output formats

| Format    | Use it for                                                                |
|-----------|---------------------------------------------------------------------------|
| `text`    | Human review at the terminal — grouped by category, color-coded, full why and fixes. |
| `compact` | grep/sed workflows. One line per finding: `file:line: severity [id] title — message`. |
| `json`    | CI integration, dashboards, anything that wants the full structured shape. |
| `llm`     | NDJSON (one diagnostic per line), each augmented with a `markdown` field rendered for LLM consumption. |

### Baseline / freeze

Adopting Archdo on an existing codebase usually surfaces hundreds of pre-existing issues. Use the freeze workflow to accept them as a baseline and only flag *new* violations going forward:

```bash
mix archdo --freeze          # capture current state in .archdo_baseline.exs
git add .archdo_baseline.exs
mix archdo                   # only new violations are shown
mix archdo --freeze-stats    # see what's been resolved since the baseline
mix archdo --show-all        # bypass the baseline
```

## MCP server (for LLM clients)

Archdo ships an MCP (Model Context Protocol) server so any LLM client — Claude Code, Cursor, Cline, Zed, Codex — can call Archdo's analysis directly:

```bash
mix archdo.mcp
```

The server speaks newline-delimited JSON-RPC 2.0 over stdin/stdout (logs go to stderr) and exposes five tools:

| Tool                    | Purpose                                                       |
|-------------------------|---------------------------------------------------------------|
| `archdo_deep_review`    | **Full architectural review** — static analysis + a prioritized review plan the LLM follows to find issues AST analysis can't see. |
| `archdo_analyze_paths`  | Quick structural check against directories or files. Returns structured diagnostics. |
| `archdo_analyze_file`   | Analyze an in-memory source string (for code the LLM is about to write). |
| `archdo_list_rules`     | List rules, optionally filtered by category.                  |
| `archdo_explain_rule`   | Look up a rule's canonical description by id.                 |

### Configuring Claude Code

Add Archdo to a project-local `.mcp.json` (Claude Code picks it up automatically when running in that directory):

```json
{
  "mcpServers": {
    "archdo": {
      "command": "mix",
      "args": ["archdo.mcp"]
    }
  }
}
```

For global access across all projects, add the same entry to `~/.claude.json` instead.

### Configuring other clients

The same pattern works for any MCP-aware client. The command is always `mix archdo.mcp`, executed from the project root so Mix can resolve the right Elixir/OTP environment.

```jsonc
// Cursor / Cline / Zed-style config
{
  "mcpServers": {
    "archdo": {
      "command": "mix",
      "args": ["archdo.mcp"],
      "cwd": "/absolute/path/to/your/elixir/project"
    }
  }
}
```

Once configured, ask the assistant to "check this file's architecture with archdo" or "list all the OTP rules" and it will call the appropriate tool.

## Documentation

- **[GUIDE.md](GUIDE.md)** — comprehensive user guide for humans and LLMs. Start here.
- [ARCHITECTURE_RULES.md](ARCHITECTURE_RULES.md) — canonical reference for all 111 rules
- [DESIGN.md](DESIGN.md) — design notes and rationale

## License

MIT.
