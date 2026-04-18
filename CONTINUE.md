# Archdo — Development Continuation Guide

## MANDATORY: Read This Before Writing Any Code

**Load `/elixir` FIRST.** Then read the relevant subskill files INTO YOUR OWN CONTEXT before writing any Elixir:
- `~/.claude/skills/elixir/language-patterns.md` — comprehensions, reduce, multi-clause, pipeline patterns
- `~/.claude/skills/elixir/code-style.md` — module organization, readability, formatting
- `~/.claude/skills/elixir/architecture-reference.md` — boundaries, contexts, hexagonal patterns
- `~/.claude/skills/elixir/testing-reference.md` — ExUnit, Mox, assertions, test patterns

**Do NOT delegate Elixir code writing to subagents.** Subagents don't have skills loaded — the skill knowledge doesn't transfer. Read files directly so the rules are in YOUR context when you write code.

**Do it properly the first time.** Every shortcut (skipping skills, using if/else for dispatch, writing `length() > 0`, delegating understanding to agents) creates rework. Follow the Elixir skill decision tables for every control flow decision. No exceptions.

## Project Location

- **Project root:** `/home/vidar/Projects/Archdo`
- **Rule files:** `lib/archdo/rules/{boundary,module,otp,nif,testing,composition,eventsourcing,statemachine}/*.ex`
- **Test files:** `test/rules/{boundary,module,otp,nif,testing,composition,eventsourcing,statemachine}/*_test.exs`
- **Test helper:** `test/support/rule_case.ex` — provides `use Archdo.RuleCase` with `analyze/3`, `assert_clean/3`, `assert_flagged/3`
- **Runner:** `lib/archdo/runner.ex` — `@phase1_rules` (per-file) and `@graph_rules` (cross-module)
- **Main module:** `lib/archdo.ex` — `run/2`, project-level rules in `run_project_arch_rules/2`
- **MCP server:** `lib/archdo/mcp/server.ex` — JSON-RPC 2.0 over stdio, JSV input validation
- **MCP tools:** `lib/archdo/mcp/tools/` — 5 tools (analyze_paths, analyze_file, list_rules, explain_rule, deep_review)
- **Schema validator:** `lib/archdo/mcp/schema_validator.ex` — JSV validation of MCP tool arguments
- **Formatter:** `lib/archdo/formatter.ex` — 4 output formats: text, compact, json, llm
- **Config:** `lib/archdo/config.ex` — layer/context detection, `.archdo.exs` loader
- **Graph:** `lib/archdo/graph.ex` — module dependency graph
- **FunctionGraph:** `lib/archdo/function_graph.ex` — function-level call graph
- **AST helpers:** `lib/archdo/ast.ex` — parse_file, extract_functions, contains?, find_all, nif_module?, relative_path
- **Freeze:** `lib/archdo/freeze.ex` — baseline mechanism for gradual adoption

## Current State (2026-04-17)

- **122 rules** across 11 categories (boundary, module, OTP, testing, eventsourcing, statemachine, composition, NIF)
- **408 tests**, 0 failures, 18 excluded (integration/self-analysis tags)
- **103 test files** — covers most file-level rules; project-level rules (needing FunctionGraph/Graph) have less coverage
- **Dependencies:** jason, jsv (JSON Schema validation), credo (dev), dialyxir (dev)
- **Tested against 14 real projects** with zero false positives: oban, broadway, commanded, gen_lsp, finch, req, nimble_options, nimble_pool, wallaby, ecto_job, phoenix_pubsub, search_tantivy, ex_libp2p

### Recent changes
- Added JSV dependency for MCP input validation (schema_validator.ex)
- New rule 1.14 (UnvalidatedParams): flags controllers/LiveViews accepting params without validation
- FunctionGraph: fixed false positives from @spec/@type type references (in_spec flag)
- Extracted shared helpers to avoid clone duplication across rule modules

## Remaining Work

### Tests for project-level rules

About 15 rules return `[]` from `analyze/3` and implement `analyze_project/1` instead. These need test infrastructure that constructs multi-file AST lists or FunctionGraph structs:

- **Boundary:** ChattyBoundary, FunctionBoundary, Mockability, ParallelHierarchies, PrivateModuleCalls, SchemaOwnership, ShotgunSurgery
- **Module:** AdaptersWithoutBehaviour, FeatureEnvy, MainSequenceDistance, SpeculativeGenerality, SimilarCode, DuplicatedValidation
- **Testing:** CoverageGap, TestMirrorsSource
- **EventSourcing:** SharedProjections

See `test/rules/boundary/seam_integrity_test.exs` and `test/rules/boundary/graph_rules_test.exs` for multi-file test patterns.

### Integration tests

Create `test/integration/real_project_test.exs` that runs `Archdo.run/2` against known cloned repos and asserts zero false positives.

### Formatter tests

Test `Archdo.Formatter.format/2` for each output format with known diagnostics.

## Remote Repository

- **Archdo:** `git@github.com:BadBeta/archdo.git` (private)
- **Elixir skill:** `git@github.com:BadBeta/Elixir_skill.git` (public)
- **Phoenix skill:** `git@github.com:BadBeta/Phoenix_skill.git` (public)
- **Phoenix LiveView skill:** `git@github.com:BadBeta/Phoenix_LiveView_skill.git` (public)
