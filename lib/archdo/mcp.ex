defmodule Archdo.Mcp do
  @moduledoc """
  MCP (Model Context Protocol) server entry point. Exposes the
  `archdo_*` tools (analyze_paths, deep_review, perf_audit, stats,
  health, etc.) over JSON-RPC for LLM clients. Started by
  `mix archdo.mcp`. Public API.
  """

  # §§ M-Plan19 Phase 3 follow-up — public boundary for the Mcp
  # context. Internal modules (`Server`, `Encoder`, `Tools.*`,
  # `ReviewHints`) are reached only through this facade. External
  # callers (the `mix archdo.mcp` task) call `Mcp.run/0` instead of
  # `Mcp.Server.run/0`. Keeps the boundary metric honest and lets the
  # internal layout change without breaking the task.

  alias Archdo.Mcp.Server

  @doc "Start the MCP JSON-RPC stdio server. Blocks until stdin closes."
  defdelegate run(), to: Server
end
