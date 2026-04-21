defmodule Archdo.Mcp.Tools.Suggest do
  @moduledoc false

  alias Archdo.Mcp.Encoder
  alias Archdo.Runner

  def name, do: "archdo_suggest"

  def description do
    "Given a file being edited, return the most relevant Archdo findings AND " <>
      "proactive suggestions for what to watch for. Tailored to the file type: " <>
      "GenServer files get OTP rules, LiveView files get boundary rules, " <>
      "test files get testing rules, context modules get architecture rules."
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "file" => %{
          "type" => "string",
          "description" => "Path to the file being edited."
        }
      },
      "required" => ["file"],
      "additionalProperties" => false
    }
  end

  def call(%{"file" => file}) do
    case File.exists?(file) do
      true ->
        diagnostics = Runner.analyze([file], [])
        file_type = classify_file(file)
        suggestions = suggestions_for(file_type)

        {:ok, %{
          file: file,
          file_type: file_type,
          findings: Encoder.encode_diagnostics(diagnostics),
          suggestions: suggestions
        }}

      false ->
        {:error, "File not found: #{file}"}
    end
  end

  def call(_), do: {:error, "Missing required argument: file"}

  defp classify_file(file) do
    cond do
      String.contains?(file, "/test/") -> :test
      String.contains?(file, "_live.ex") or String.contains?(file, "/live/") -> :liveview
      String.contains?(file, "_controller.ex") or String.contains?(file, "/controllers/") -> :controller
      String.contains?(file, "mix.exs") -> :mix
      String.ends_with?(file, "/native.ex") or String.contains?(file, "/native/") -> :nif
      true -> detect_from_content(file)
    end
  end

  defp detect_from_content(file) do
    case File.read(file) do
      {:ok, content} ->
        cond do
          String.contains?(content, "use GenServer") -> :genserver
          String.contains?(content, "use GenStateMachine") or String.contains?(content, ":gen_statem") -> :state_machine
          String.contains?(content, "use Commanded") -> :event_sourcing
          String.contains?(content, "use Ecto.Schema") -> :schema
          String.contains?(content, "use Supervisor") or String.contains?(content, "use DynamicSupervisor") -> :supervisor
          true -> :module
        end

      {:error, _} ->
        :module
    end
  end

  defp suggestions_for(:genserver) do
    [
      "Check handle_call/cast/info for blocking operations (HTTP, DB, file I/O)",
      "Ensure GenServer.call has explicit timeouts for cross-process calls",
      "Consider catch :exit for GenServer.call to processes you don't own",
      "Keep business logic in pure functions — GenServer handles process mechanics only",
      "Check if this GenServer has too many message patterns (rule 5.43)"
    ]
  end

  defp suggestions_for(:liveview) do
    [
      "Keep handle_event bodies thin — delegate to context modules",
      "Check socket assigns count (rule 4.15 flags >15 assigns)",
      "Verify all associations are preloaded before rendering",
      "Use streams for large collections instead of assigns"
    ]
  end

  defp suggestions_for(:controller) do
    [
      "Controllers should only translate input, delegate to context, format output",
      "Check for business logic that should be in a context module",
      "Validate params at the boundary (rule 4.15)"
    ]
  end

  defp suggestions_for(:test) do
    [
      "Use start_supervised! instead of bare start_link (rule 7.26)",
      "Avoid :sys.get_state — test observable behavior, not internal state",
      "Add explicit timeouts to assert_receive (rule 7.29)",
      "Check error paths, not just happy paths (rule 7.22)"
    ]
  end

  defp suggestions_for(:nif) do
    [
      "Ensure NIF is behind a behaviour for test mocking (rule 11.2)",
      "Check for panic-inducing patterns in Rust code (rule 11.1)",
      "Verify dirty scheduler usage for operations >1ms (rule 11.3)"
    ]
  end

  defp suggestions_for(:supervisor) do
    [
      "Verify restart strategy matches child dependencies",
      "Check max_restarts/max_seconds aren't using defaults (rule 5.6)",
      "Ensure start order matches dependency order"
    ]
  end

  defp suggestions_for(:event_sourcing) do
    [
      "Keep apply/2 pure — no side effects, no I/O (rule 8.2)",
      "Events must be immutable — no mutable state in event structs (rule 8.3)",
      "Command handlers (execute) should validate, apply should just update state"
    ]
  end

  defp suggestions_for(:schema) do
    [
      "Check struct field count (rule 6.3 flags >25 fields)",
      "Keep Repo calls in context modules, not in schema modules"
    ]
  end

  defp suggestions_for(:mix) do
    [
      "Check dev deps have only: [:dev, :test] (rule 4.29)",
      "Verify umbrella deps have consistent options (rule 4.30)"
    ]
  end

  defp suggestions_for(:state_machine) do
    [
      "Check for unreachable states (rule 9.1)",
      "Verify terminal states can't transition further (rule 9.2)"
    ]
  end

  defp suggestions_for(:module) do
    [
      "Check cyclomatic complexity (rule 6.2 flags >9)",
      "Verify public functions have @spec and @doc",
      "Look for single-clause with that should be case (rule 6.41)"
    ]
  end
end
