# Archdo — Claude Code Instructions

This is an Elixir project. Before writing or editing ANY Elixir code, load the Elixir skill: `/elixir`

Follow the skill's rules and decision tables for all control flow, error handling, and data transformation decisions. Do not write imperative patterns (if/else for dispatch, length() > 0, try/rescue for expected failures).

When reviewing external Elixir projects with Archdo, use the two-layer workflow:
1. Run `mix archdo --paths /path/to/lib --format compact`
2. Load the Elixir skill and relevant subskills to evaluate findings
