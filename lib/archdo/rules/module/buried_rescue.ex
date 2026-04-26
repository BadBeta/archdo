defmodule Archdo.Rules.Module.BuriedRescue do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.32"

  @impl true
  def description,
    do: "try/rescue buried inside anonymous function or callback — extract to named function"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_buried_rescues(file, ast)
    end
  end

  defp find_buried_rescues(file, ast) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        # try/rescue inside Enum.map/flat_map/each/reduce callback
        # Check this BEFORE the fn pattern to avoid double-flagging
        {{:., _, [{:__aliases__, _, [:Enum]}, enum_fn]}, meta, [_collection, callback]} = node,
        acc
        when enum_fn in [:map, :flat_map, :each, :reduce] ->
          case contains_try_rescue?(callback) do
            # Return nil instead of node to stop prewalk from recursing into callback
            true -> {nil, [build_diagnostic(file, meta, {:enum_callback, enum_fn}) | acc]}
            false -> {node, acc}
          end

        # try/rescue inside Task.async/Task.async_stream callback
        {{:., _, [{:__aliases__, _, [:Task]}, task_fn]}, meta, _args} = node, acc
        when task_fn in [:async, :async_stream] ->
          case contains_try_rescue?(node) do
            true -> {nil, [build_diagnostic(file, meta, {:task_callback, task_fn}) | acc]}
            false -> {node, acc}
          end

        # try/rescue inside standalone fn -> ... end (not already caught by Enum/Task)
        {:fn, _, [{:->, _, [_args, body]}]} = node, acc ->
          case contains_try_rescue?(body) do
            true -> {nil, [build_diagnostic(file, node, :anonymous_function) | acc]}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(diagnostics)
  end

  defp contains_try_rescue?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        # Don't recurse into nested def/defp — those are their own scope
        {:def, _, _} = node, acc ->
          {node, acc}

        {:defp, _, _} = node, acc ->
          {node, acc}

        {:try, _, [opts]} = node, _acc when is_list(opts) ->
          case Keyword.has_key?(opts, :rescue) do
            true -> {node, true}
            false -> {node, false}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp build_diagnostic(file, node_or_meta, context) do
    line =
      case node_or_meta do
        {_, meta, _} -> AST.line(meta)
        meta when is_list(meta) -> AST.line(meta)
        _ -> 0
      end

    {location_desc, extract_name} =
      case context do
        :anonymous_function ->
          {"anonymous function", "a named private function"}

        {:enum_callback, enum_fn} ->
          {"Enum.#{enum_fn} callback", "a named private function like safe_process/1"}

        {:task_callback, task_fn} ->
          {"Task.#{task_fn} callback", "a named private function"}
      end

    Diagnostic.info("6.32",
      title: "Buried try/rescue",
      message: "try/rescue inside #{location_desc} — extract to a named function for clarity",
      why:
        "A try/rescue block buried inside an anonymous function, Enum callback, or " <>
          "case branch is hard to read and obscures the error handling intent. The rescue " <>
          "clause silently converts exceptions to fallback values, which can mask bugs. " <>
          "Extracting to a named function (like safe_process/1) makes the fault isolation " <>
          "visible at the call site and documents that exceptions are expected.",
      alternatives: [
        Fix.new(
          summary: "Extract to #{extract_name}",
          detail:
            "Move the try/rescue body into a named private function. " <>
              "The function name should indicate it handles errors " <>
              "(e.g., safe_call, try_parse, attempt_process).",
          applies_when: "The try/rescue isolates expected failures from external code."
        ),
        Fix.new(
          summary: "Replace with ok/error tuple handling",
          detail:
            "If the function inside try has a non-bang variant that returns " <>
              "{:ok, _} | {:error, _}, use that instead of rescuing the bang version.",
          applies_when: "A non-bang variant exists (e.g., File.read vs File.read!)."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.32"],
      context: %{location: location_desc},
      file: file,
      line: line
    )
  end
end
