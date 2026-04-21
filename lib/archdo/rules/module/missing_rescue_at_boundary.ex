defmodule Archdo.Rules.Module.MissingRescueAtBoundary do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.16"

  @impl true
  def description,
    do: "System boundary calls (external data, process calls) need rescue/catch, not just ok/error"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_unprotected_genserver_calls(file, ast) ++
        find_unprotected_deserialization(file, ast)
    end
  end

  # Detect GenServer.call to a variable PID (not __MODULE__ or atom) without catch :exit
  defp find_unprotected_genserver_calls(file, ast) do
    fns = AST.extract_functions(ast, :all)

    Enum.flat_map(fns, fn {_name, _arity, _meta, _args, body} ->
      find_genserver_calls_without_catch(body, file)
    end)
  end

  defp find_genserver_calls_without_catch(nil, _file), do: []

  defp find_genserver_calls_without_catch(body, file) do
    # Find GenServer.call with variable PID (not __MODULE__, not atom name)
    calls =
      AST.find_all(body, fn
        {{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, _, [target | _]} ->
          variable_pid?(target)

        _ ->
          false
      end)

    # Check if the function body has a catch :exit wrapping these calls
    has_catch =
      AST.contains?(body, fn
        {:catch, clauses} when is_list(clauses) ->
          Enum.any?(clauses, fn
            {:->, _, [[:exit, _], _]} -> true
            {:->, _, [[{:exit, _, _}], _]} -> true
            _ -> false
          end)

        _ ->
          false
      end)

    if calls != [] and not has_catch do
      Enum.map(calls, fn {_, meta, _} ->
        build_genserver_diagnostic(file, AST.line(meta))
      end)
    else
      []
    end
  end

  defp variable_pid?({:__MODULE__, _, _}), do: false
  defp variable_pid?(atom) when is_atom(atom), do: false
  defp variable_pid?({:__block__, _, [atom]}) when is_atom(atom), do: false
  defp variable_pid?(_), do: true

  # Detect :erlang.binary_to_term or similar without rescue
  defp find_unprotected_deserialization(file, ast) do
    fns = AST.extract_functions(ast, :all)

    Enum.flat_map(fns, fn {_name, _arity, _meta, _args, body} ->
      find_deserialization_without_rescue(body, file)
    end)
  end

  defp find_deserialization_without_rescue(nil, _file), do: []

  defp find_deserialization_without_rescue(body, file) do
    calls =
      AST.find_all(body, fn
        {{:., _, [:erlang, :binary_to_term]}, _, _} -> true
        _ -> false
      end)

    has_rescue =
      AST.contains?(body, fn
        {:rescue, _} -> true
        _ -> false
      end)

    if calls != [] and not has_rescue do
      Enum.map(calls, fn {_, meta, _} ->
        build_deser_diagnostic(file, AST.line(meta))
      end)
    else
      []
    end
  end

  defp build_genserver_diagnostic(file, line) do
    Diagnostic.info("6.16",
      title: "GenServer.call to variable PID without catch :exit",
      message:
        "GenServer.call/2,3 targets a variable PID — needs `catch :exit` for process death",
      why:
        "When calling a GenServer by a variable PID (not __MODULE__ or a known atom name), " <>
          "the target process may have died between the time you obtained the PID and the call. " <>
          "GenServer.call raises an :exit (not an exception), so `rescue` doesn't catch it. " <>
          "Use `catch :exit` as LiveView, Oban, and db_connection do. Without it, the caller " <>
          "process crashes on a predictable failure mode.",
      alternatives: [
        Fix.new(
          summary: "Wrap in `try do ... catch :exit, _ -> {:error, :down} end`",
          detail:
            "The standard pattern used by production libraries (LiveView, Oban, db_connection):\n\n" <>
              "```elixir\n" <>
              "try do\n" <>
              "  GenServer.call(pid, :request)\n" <>
              "catch\n" <>
              "  :exit, _ -> {:error, :process_down}\n" <>
              "end\n" <>
              "```",
          applies_when: "The caller should handle process death gracefully."
        ),
        Fix.new(
          summary: "Check with GenServer.whereis/1 first, then catch :exit for TOCTOU",
          detail:
            "For optional services, check if the process exists first with " <>
              "`GenServer.whereis(name)`, then still wrap in `catch :exit` for the " <>
              "race condition where the process dies between check and call.",
          applies_when: "The service is optional and may not be running."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.16"],
      context: %{kind: :genserver_call},
      file: file,
      line: line
    )
  end

  defp build_deser_diagnostic(file, line) do
    Diagnostic.warning("6.16",
      title: "Untrusted data deserialization without rescue",
      message:
        ":erlang.binary_to_term called without rescue — malformed input crashes the process",
      why:
        ":erlang.binary_to_term on untrusted input can raise on malformed data, and with " <>
          "the `:safe` option it raises on unknown atoms. This is a system boundary where " <>
          "rescue is the correct pattern — the input is external and may be anything.",
      alternatives: [
        Fix.new(
          summary: "Wrap in try/rescue and validate the result",
          detail:
            "```elixir\n" <>
              "try do\n" <>
              "  {:ok, :erlang.binary_to_term(data, [:safe])}\n" <>
              "rescue\n" <>
              "  ArgumentError -> {:error, :malformed_term}\n" <>
              "end\n" <>
              "```",
          applies_when: "Always — external binary data is untrusted."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.16"],
      context: %{kind: :deserialization},
      file: file,
      line: line
    )
  end
end
