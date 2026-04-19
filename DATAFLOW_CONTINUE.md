# Archdo Visualization — Dataflow Diagrams Continuation

## Context

Archdo generates architectural diagrams from compiled beam analysis. The current implementation includes Mermaid diagrams (11 types) and SVG diagrams (4 types) covering module dependencies, contexts, blast radius, OTP topology, system architecture, and AST vs compiled delta comparison.

The next phase is to evolve the SVG diagrams into a LabVIEW/Grasshopper-inspired visual programming representation of Elixir code.

## Research Completed

### LabVIEW (researched 2026-04-19)

Key techniques for clean diagrams:
- **Sugiyama layered graph layout** — assign nodes to columns by dependency depth, minimize crossings, compact vertically
- **Terminal alignment** — position connected nodes so ports share same Y coordinate → straight horizontal wires with zero bends (single biggest impact on readability)
- **One-screen constraint** — max 30-40 nodes per visible unit; force hierarchical abstraction beyond that
- **Orthogonal wire routing** — Manhattan-style (horizontal + vertical only), minimize bends
- **Cluster/bundle wires** — group related edges into single compound wires to reduce visual complexity
- **Error wire threading** — single wire chain through all nodes, maps to Elixir's `{:ok, _} | {:error, _}` chains
- **SubVIs for abstraction** — any VI used as node in another (like function composition), drill-down on double-click
- **Clean Up Diagram (Ctrl+U)** — auto-layout algorithm

### Grasshopper (researched 2026-04-19)

Key techniques:
- **Three-level wire visibility** ��� Default (solid), Faint (semi-transparent for inter-group), Hidden (invisible with documented link)
- **Progressive disclosure via zoom** — Icons at low zoom → names at medium → full details at high zoom
- **Colored groups** as organizational containers with titles (purely visual, no logic)
- **Telepathy plugin** — wireless sender/receiver pairs eliminating long cross-canvas wires
- **AutoGraph plugin** — force-directed/hierarchical auto-layout
- **Data trees** — hierarchical data with path-keyed branches (maps to nested enumerables)
- **No loops** — implicit iteration over data trees (exactly like Enum.map)
- **BestPracticize pattern** — auto-insert explicit boundary parameters at group edges

## Current Implementation

### Diagram Types Available

| Command | Format | Description |
|---------|--------|-------------|
| `overview` | Mermaid | Contexts as subgraphs with cross-boundary deps |
| `modules` | Mermaid | All module dependencies with call counts |
| `api` | Mermaid | Public API surface per context |
| `context:Name` | Mermaid | Context detail with leak points |
| `blast:Module` | Mermaid | Blast radius with depth layers |
| `delta` | Mermaid | Full AST vs compiled comparison |
| `delta-only` | Mermaid | Only hidden + phantom differences |
| `dataflow:Module` | Mermaid | Module as component with ports |
| `dataflow-context:Name` | Mermaid | Context as instrument panel |
| `svg:Module` | SVG | LabVIEW-style component box |
| `svg-context:Name` | SVG | LabVIEW-style context |
| `otp` | SVG | OTP supervision tree with mailboxes |
| `otp-messages` | SVG | Process messaging relationships |
| `system` | SVG | Full system architecture with layers |

### SVG Architecture Files

- `lib/archdo/compiled/diagram.ex` — Mermaid generators + AST vs compiled delta
- `lib/archdo/compiled/diagram_svg.ex` — SVG module/context dataflow
- `lib/archdo/compiled/diagram_otp.ex` — SVG OTP supervision + messaging
- `lib/archdo/compiled/diagram_system.ex` — SVG system architecture layers
- `lib/archdo/compiled/otp_topology.ex` — OTP process/supervision extraction

## What to Implement Next

### Priority 1: Layout Algorithm Improvements

1. **Terminal alignment** — position connected nodes so ports share the same Y coordinate. Currently nodes are placed in grid order; should be placed to minimize wire bends.

2. **Sugiyama layered layout** — assign nodes to layers by dependency depth, then minimize crossings within each layer. Currently nodes are ordered by connection count; should use topological sort.

3. **Orthogonal wire routing** — offer Manhattan-style routing as alternative to current Bezier curves. Some diagrams look cleaner with right-angle wires.

### Priority 2: Progressive Zoom (Grasshopper-style)

Generate multiple SVG viewports at different detail levels:
- **Overview**: context boxes only (no individual modules)
- **Medium**: modules as boxes with names, no function lists
- **Detail**: full module with export list, types, ports

Could be implemented as nested SVG `<g>` elements with CSS visibility based on `viewBox` zoom level, or as separate SVG outputs.

### Priority 3: Wire Type Encoding from @spec

Extract `@spec` return types from beam debug_info to color-code wires:
- **Blue** — `{:ok, _} | {:error, _}` (already partially done)
- **Green** — list/enumerable
- **Purple** — map/struct
- **Orange** — atom
- **Grey dashed** — `Stream.t()` / lazy
- **Thin** — single value
- **Thick** — collection

### Priority 4: Interactive HTML Output

Generate HTML with embedded SVG + JavaScript for:
- Pan/zoom with mouse
- Click module to drill down into its internal diagram
- Hover wire to see function name and call count
- Search box to find and highlight a module
- Named views/bookmarks (Grasshopper-style)

### Priority 5: OTP Process Visualization Improvements

- **Message flow animation** — show message direction on wires (CSS animation)
- **Mailbox depth indicator** — visual fill level on mailbox icons
- **Supervision restart strategy visualization** — different frame styles for :one_for_one vs :rest_for_one vs :one_for_all
- **Error kernel boundary** — visual separator between stable infrastructure and volatile workers

### Priority 6: State Machine Embedding

When a module is a gen_statem or state machine:
- Render states as circles inside the module box
- Draw transition arrows between states with event labels
- Color states: green=initial, blue=active, red=error, grey=terminal
- Extract states from compiled clause patterns on the state dispatch function

## Design Decisions Made

1. **Horizontal layers** (top to bottom) for system architecture — solves bidirectional communication without awkward back-routing
2. **LabVIEW tunnel pattern** for cross-layer connections — output tunnels on bottom edge, input tunnels on left edge, orthogonal wire routing
3. **Dark theme** (Catppuccin Mocha) for SVG — better contrast for colored wires and ports
4. **Modules prioritized by connection count** — most architecturally significant modules shown first when space is limited
5. **OTP mailbox model** — incoming queue (top-left), outgoing queue (bottom-right) per process box
6. **Supervisor as containing frame** — nested frames for nested supervision, dashed border to distinguish from module boxes
