defmodule Archdo.Rules.OTP.CallbackSprawl do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @callback_names [:handle_call, :handle_cast, :handle_info]
  @threshold 10

  @impl true
  def id, do: "5.43"

  @impl true
  def description,
    do: "GenServer with too many distinct callback message patterns — consider splitting"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> check_sprawl(file, ast)
    end
  end

  defp check_sprawl(file, ast) do
    case AST.uses_genserver?(ast) do
      false ->
        []

      true ->
        callbacks = AST.extract_callbacks(ast)

        distinct_count =
          @callback_names
          |> Enum.map(fn name -> count_distinct_messages(callbacks[name] || []) end)
          |> Enum.sum()

        case distinct_count > @threshold do
          true -> [build_diagnostic(file, ast, distinct_count)]
          false -> []
        end
    end
  end

  defp count_distinct_messages(clauses) do
    clauses
    |> Enum.map(&extract_message_pattern/1)
    |> Enum.uniq()
    |> length()
  end

  # Extract the first argument (message pattern) from a callback clause.
  # handle_call has (message, from, state), handle_cast/info have (message, state).
  defp extract_message_pattern({_meta, [first_arg | _rest], _body}) do
    normalize_pattern(first_arg)
  end

  defp extract_message_pattern(_), do: :unknown

  # Normalize AST patterns to a comparable form by stripping metadata and
  # replacing variable names with a placeholder. This groups clauses that match
  # the same structural pattern.
  defp normalize_pattern({name, _meta, args}) when is_atom(name) and is_list(args) do
    {name, [], Enum.map(args, &normalize_pattern/1)}
  end

  defp normalize_pattern({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    {:_, [], nil}
  end

  defp normalize_pattern({left, right}) do
    {normalize_pattern(left), normalize_pattern(right)}
  end

  defp normalize_pattern(list) when is_list(list) do
    Enum.map(list, &normalize_pattern/1)
  end

  defp normalize_pattern(literal), do: literal

  defp build_diagnostic(file, ast, count) do
    module_name = AST.extract_module_name(ast)

    Diagnostic.warning("5.43",
      title: "GenServer callback sprawl: #{module_name}",
      message:
        "#{module_name} has #{count} distinct callback message patterns (threshold: #{@threshold}) — " <>
          "the GenServer is handling too many responsibilities",
      why:
        "A GenServer with many distinct message types is doing too much. " <>
          "Each message pattern is a separate responsibility. Extract related " <>
          "messages into dedicated GenServers or delegate to pure function modules.",
      alternatives: [
        Fix.new(
          summary: "Split into multiple GenServers by responsibility",
          detail:
            "Group related handle_call/cast/info clauses and extract them into " <>
              "separate GenServer modules, each with a focused purpose.",
          applies_when: "Message groups operate on independent subsets of state."
        ),
        Fix.new(
          summary: "Delegate to pure function modules",
          detail:
            "Keep the GenServer as a thin state holder and delegate business logic " <>
              "to plain modules with pure functions.",
          applies_when: "The complexity is in the logic, not the state management."
        )
      ],
      file: file,
      line: 1
    )
  end
end
