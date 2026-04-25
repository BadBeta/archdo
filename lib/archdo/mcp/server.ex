defmodule Archdo.Mcp.Server do
  @moduledoc false

  # Minimal stdio MCP server for Archdo. Implements just enough of the
  # Model Context Protocol to expose Archdo's analysis as tools that LLMs
  # (Claude Code, Cursor, Cline, Zed, etc.) can call.
  #
  # Transport: newline-delimited JSON-RPC 2.0 over stdin/stdout. Logging
  # goes to stderr so it doesn't corrupt the protocol stream.
  #
  # Spec: https://modelcontextprotocol.io/specification

  alias Archdo.Mcp.SchemaValidator

  alias Archdo.Mcp.Tools.{
    AnalyzeFile, AnalyzePaths, DeepReview, Diagram, Diff,
    ExplainFinding, ExplainRule, Fix, Health, ListRules, PerfAudit, Stats, Suggest
  }

  @protocol_version "2024-11-05"
  @server_name "archdo"
  @server_version Mix.Project.config()[:version] || "0.0.0"

  @tools [
    AnalyzePaths, AnalyzeFile, ListRules, ExplainRule, DeepReview,
    Health, Diff, Diagram, PerfAudit, Suggest, ExplainFinding, Fix, Stats
  ]

  @doc """
  Run the server loop forever, reading JSON-RPC messages from stdin
  and writing responses to stdout. Returns when stdin is closed.
  """
  @spec run() :: :ok
  def run do
    log("archdo MCP server starting (#{@server_version})")
    loop()
  end

  defp loop do
    case IO.gets(:stdio, "") do
      :eof ->
        log("stdin closed, shutting down")
        :ok

      {:error, reason} ->
        log("stdin read error: #{inspect(reason)}")
        :ok

      data when is_binary(data) ->
        line = String.trim_trailing(data, "\n")

        if line != "" do
          handle_line(line)
        end

        loop()
    end
  end

  defp handle_line(line) do
    case Jason.decode(line) do
      {:ok, request} ->
        case dispatch(request) do
          :notification ->
            :ok

          response when is_map(response) ->
            write_response(response)
        end

      {:error, decode_error} ->
        log("malformed JSON: #{inspect(decode_error)}")

        write_response(%{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32_700, "message" => "Parse error"}
        })
    end
  rescue
    e ->
      log("unhandled error: #{Exception.format(:error, e, __STACKTRACE__)}")

      # Extract request id if possible so the client doesn't hang
      request_id =
        case Jason.decode(line) do
          {:ok, %{"id" => id}} -> id
          _ -> nil
        end

      write_response(%{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "error" => %{"code" => -32_603, "message" => "Internal error"}
      })
  end

  # ─────────────────────────────────── dispatch ────────────────────────────────────

  defp dispatch(%{"method" => method, "id" => id} = req) do
    handle_method(method, Map.get(req, "params", %{}), id)
  end

  # Notification (no id) — no response, just side effects
  defp dispatch(%{"method" => method} = req) do
    handle_notification(method, Map.get(req, "params", %{}))
    :notification
  end

  defp dispatch(_), do: :notification

  # ─────────────────────────────────── methods ─────────────────────────────────────

  defp handle_method("initialize", _params, id) do
    success(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{
        "tools" => %{"listChanged" => false}
      },
      "serverInfo" => %{
        "name" => @server_name,
        "version" => @server_version
      }
    })
  end

  defp handle_method("tools/list", _params, id) do
    success(id, %{
      "tools" =>
        Enum.map(@tools, fn tool ->
          %{
            "name" => tool.name(),
            "description" => tool.description(),
            "inputSchema" => tool.input_schema()
          }
        end)
    })
  end

  defp handle_method("tools/call", %{"name" => name} = params, id) do
    arguments = Map.get(params, "arguments", %{})

    case find_tool(name) do
      nil ->
        error(id, -32_602, "unknown tool: #{name}")

      tool ->
        case safe_call(tool, arguments) do
          {:ok, result} ->
            success(id, %{
              "content" => [
                %{
                  "type" => "text",
                  "text" => Jason.encode!(result, pretty: true)
                }
              ],
              "structuredContent" => result,
              "isError" => false
            })

          {:error, message} ->
            success(id, %{
              "content" => [%{"type" => "text", "text" => message}],
              "isError" => true
            })
        end
    end
  end

  defp handle_method("ping", _params, id), do: success(id, %{})

  defp handle_method(method, _params, id) do
    error(id, -32_601, "method not found: #{method}")
  end

  defp handle_notification("notifications/initialized", _), do: :ok
  defp handle_notification(_method, _params), do: :ok

  # ─────────────────────────────────── helpers ─────────────────────────────────────

  defp find_tool(name), do: Enum.find(@tools, fn tool -> tool.name() == name end)

  defp safe_call(tool, arguments) do
    case SchemaValidator.validate(tool, arguments) do
      {:ok, validated} ->
        tool.call(validated)

      {:error, message} ->
        {:error, "Invalid arguments: #{message}"}
    end
  rescue
    e ->
      log("tool #{tool.name()} crashed: #{inspect(e)}")
      {:error, "tool error: #{Exception.message(e)}"}
  end

  defp success(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error(id, code, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }
  end

  defp write_response(response) do
    json = Jason.encode!(response)
    IO.puts(:stdio, json)
  end

  defp log(msg) do
    IO.puts(:standard_error, "[archdo.mcp] #{msg}")
  end
end
