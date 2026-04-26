defmodule Archdo.Rules.OTP.MissingTerminate do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.16"

  @impl true
  def description, do: "GenServers holding resources should implement terminate/2"

  @resource_patterns [
    {[:File], :open},
    {[:File], :open!},
    {:gen_tcp, :connect},
    {:gen_udp, :open},
    {[:Port], :open}
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.genserver_module?(ast) do
      false ->
        []

      true ->
        callbacks = AST.extract_callbacks(ast)
        has_terminate? = callbacks[:terminate] != []

        if has_terminate? do
          []
        else
          find_resource_acquisition(file, ast)
        end
    end
  end

  defp find_resource_acquisition(file, ast) do
    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, _meta, _args} ->
        Enum.any?(@resource_patterns, fn
          {mod, f} when is_list(mod) -> mod_parts == mod and func == f
          _ -> false
        end)

      {{:., _, [mod, func]}, _meta, _args} when is_atom(mod) ->
        Enum.any?(@resource_patterns, fn
          {m, f} when is_atom(m) -> mod == m and func == f
          _ -> false
        end)

      _ ->
        false
    end)
    |> Enum.take(1)
    |> Enum.map(fn {_, meta, _} ->
      Diagnostic.info("5.16",
        title: "External resource without terminate/2",
        message:
          "GenServer acquires an external resource (file/socket/port) but does not implement terminate/2",
        why:
          "File handles, sockets, and ports are finite OS resources. BEAM eventually reclaims them when the " <>
            "owning process dies, but during a restart loop the next process starts before the OS catches up, " <>
            "leaking handles until the system runs out. terminate/2 lets the GenServer release resources cleanly " <>
            "on planned shutdowns and supervisor `:shutdown` signals.",
        alternatives: [
          Fix.new(
            summary: "Implement terminate/2 to release the resource",
            detail:
              "Add a `terminate(_reason, state)` clause that closes the file/socket/port. Note: terminate/2 " <>
                "only runs on `:shutdown` signals or when the process traps exits — for crashes that bypass " <>
                "supervisor shutdown, also link the resource to a process that owns it.",
            example: """
            ```elixir
            def terminate(_reason, %{file: file}) do
              File.close(file)
            end
            ```
            """,
            applies_when: "The GenServer owns the resource for its entire lifetime."
          ),
          Fix.new(
            summary:
              "Move the resource into a child process or supervisor-owned ETS table with `:heir`",
            detail:
              "Create the resource in a parent supervisor (or supervisor's start callback) and pass it down. " <>
                "It now outlives the GenServer's restart cycles and there is nothing to release on shutdown.",
            applies_when: "The resource should survive child process restarts."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.16"],
        context: %{},
        file: file,
        line: AST.line(meta)
      )
    end)
  end
end
