defmodule Mix.Tasks.Archdo.Mcp do
  @shortdoc "Run Archdo as an MCP server over stdio"
  @moduledoc """
  Run Archdo as a Model Context Protocol server, exposing analysis as
  callable tools to LLM clients (Claude Code, Cursor, Cline, Zed, etc.).

      mix archdo.mcp

  The server reads JSON-RPC 2.0 messages from stdin (one per line) and
  writes responses to stdout. Logging goes to stderr.

  ## Tools

    * `archdo_analyze_paths` — analyze directories or files and return diagnostics
    * `archdo_analyze_file` — analyze an in-memory source string
    * `archdo_list_rules` — list all rules, optionally filtered by category
    * `archdo_explain_rule` — look up a rule's description by id

  ## Configuring an MCP client

  Most clients accept a JSON config like:

      {
        "mcpServers": {
          "archdo": {
            "command": "mix",
            "args": ["archdo.mcp"],
            "cwd": "/path/to/your/elixir/project"
          }
        }
      }

  Run from inside the project directory so `mix` finds the right environment.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    # MCP wants the application running so the rule modules are loaded.
    Mix.Task.run("app.config")

    # Run the server loop in the foreground until stdin closes.
    Archdo.Mcp.Server.run()
  end
end
