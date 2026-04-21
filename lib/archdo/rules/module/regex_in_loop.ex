defmodule Archdo.Rules.Module.RegexInLoop do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @enum_fns [:map, :filter, :reduce, :any?, :find, :each, :flat_map, :reject, :map_reduce]

  @genserver_callbacks [:handle_call, :handle_cast, :handle_info, :handle_continue]

  @impl true
  def id, do: "6.49"

  @impl true
  def description, do: "Regex literal in hot path — recompiled each call, hoist to module attribute"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_regex_in_hot_paths(ast, file)
    end
  end

  defp find_regex_in_hot_paths(ast, file) do
    enum_hits = find_regex_in_enum_callbacks(ast, file)
    for_hits = find_regex_in_for_comprehensions(ast, file)
    genserver_hits = find_regex_in_genserver_callbacks(ast, file)
    enum_hits ++ for_hits ++ genserver_hits
  end

  # Regex inside Enum.map/filter/reduce/any?/find callback functions
  defp find_regex_in_enum_callbacks(ast, file) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Enum]}, func]}, meta, args} = node, acc
        when func in @enum_fns and is_list(args) ->
          # Check the callback argument (last arg for most, or the fn arg)
          new_diags =
            args
            |> Enum.filter(&is_fn_or_capture?/1)
            |> Enum.flat_map(fn callback ->
              case AST.contains?(callback, &regex_sigil?/1) do
                true -> [build_diagnostic(file, AST.line(meta), :enum_callback, func)]
                false -> []
              end
            end)

          {node, new_diags ++ acc}

        node, acc ->
          {node, acc}
      end)

    diagnostics
  end

  # Regex inside for comprehensions
  defp find_regex_in_for_comprehensions(ast, file) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        {:for, meta, args} = node, acc when is_list(args) ->
          # Check the do block for regex sigils
          do_block = extract_do_block(args)

          case do_block != nil and AST.contains?(do_block, &regex_sigil?/1) do
            true -> {node, [build_diagnostic(file, AST.line(meta), :for_comprehension, nil) | acc]}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    diagnostics
  end

  # Regex inside GenServer callbacks (handle_call/cast/info/continue)
  defp find_regex_in_genserver_callbacks(ast, file) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [{callback, _, _} | _]} = node, acc
        when callback in @genserver_callbacks ->
          case AST.contains?(node, &regex_sigil?/1) do
            true ->
              {node, [build_diagnostic(file, AST.line(meta), :genserver_callback, callback) | acc]}

            false ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    diagnostics
  end

  defp regex_sigil?({:sigil_r, _, _}), do: true
  defp regex_sigil?({:sigil_R, _, _}), do: true
  defp regex_sigil?(_), do: false

  defp is_fn_or_capture?({:fn, _, _}), do: true
  defp is_fn_or_capture?({:&, _, _}), do: true
  defp is_fn_or_capture?(_), do: false

  defp extract_do_block(args) do
    Enum.find_value(args, fn
      [do: body] -> body
      {:do, body} -> body
      _ -> nil
    end)
  end

  defp build_diagnostic(file, line, context, detail) do
    location =
      case context do
        :enum_callback -> "Enum.#{detail}/_ callback"
        :for_comprehension -> "for comprehension"
        :genserver_callback -> "#{detail}/3 callback"
      end

    Diagnostic.info("6.49",
      title: "Regex literal in #{location}",
      message: "~r/.../ inside #{location} is recompiled on every invocation",
      why:
        "Regex sigils in module bodies and function heads are compiled once at compile time. " <>
          "However, inside function bodies (especially loops and callbacks), the regex " <>
          "may be recompiled each call. Hoist to a module attribute: " <>
          "`@my_pattern ~r/pattern/` to guarantee single compilation.",
      alternatives: [
        Fix.new(
          summary: "Hoist regex to a module attribute",
          detail:
            "Add `@my_pattern ~r/pattern/` at the top of the module, " <>
              "then reference `@my_pattern` in the function body.",
          applies_when: "Regex is used inside a loop, callback, or frequently-called function."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end
end
