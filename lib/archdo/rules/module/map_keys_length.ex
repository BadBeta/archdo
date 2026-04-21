defmodule Archdo.Rules.Module.MapKeysLength do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.48"

  @impl true
  def description, do: "Map.keys/values |> length() — O(n), use map_size/1 which is O(1)"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_map_keys_length(ast, file)
    end
  end

  defp find_map_keys_length(ast, file) do
    piped = find_piped_pattern(ast, file)
    wrapped = find_wrapped_pattern(ast, file)
    piped ++ wrapped
  end

  # Map.keys(m) |> length() or Map.keys(m) |> Enum.count()
  # Map.values(m) |> length() or Map.values(m) |> Enum.count()
  defp find_piped_pattern(ast, file) do
    ast
    |> AST.find_all(fn
      {:|>, _, [map_keys_or_values_call, length_or_count_call]} ->
        map_keys_or_values?(map_keys_or_values_call) and
          length_or_count?(length_or_count_call)

      _ ->
        false
    end)
    |> Enum.map(fn {:|>, meta, [left, _]} ->
      func = extract_map_func(left)
      build_diagnostic(file, AST.line(meta), func, :piped)
    end)
  end

  # length(Map.keys(m)) or Enum.count(Map.keys(m))
  # length(Map.values(m)) or Enum.count(Map.values(m))
  defp find_wrapped_pattern(ast, file) do
    ast
    |> AST.find_all(fn
      {:length, _, [inner]} ->
        map_keys_or_values?(inner)

      {{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [inner]} ->
        map_keys_or_values?(inner)

      _ ->
        false
    end)
    |> Enum.map(fn
      {:length, meta, [inner]} ->
        func = extract_map_func(inner)
        build_diagnostic(file, AST.line(meta), func, :wrapped)

      {{:., _, _}, meta, [inner]} ->
        func = extract_map_func(inner)
        build_diagnostic(file, AST.line(meta), func, :wrapped)
    end)
  end

  defp map_keys_or_values?({{:., _, [{:__aliases__, _, [:Map]}, func]}, _, [_]})
       when func in [:keys, :values],
       do: true

  defp map_keys_or_values?(_), do: false

  defp length_or_count?({:length, _, []}), do: true
  defp length_or_count?({:length, _, _}), do: true

  defp length_or_count?({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, []}),
    do: true

  defp length_or_count?({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, _}),
    do: true

  defp length_or_count?(_), do: false

  defp extract_map_func({{:., _, [{:__aliases__, _, [:Map]}, func]}, _, _}), do: func
  defp extract_map_func(_), do: :keys

  defp build_diagnostic(file, line, map_func, _style) do
    Diagnostic.info("6.48",
      title: "Map.#{map_func} |> length() is O(n)",
      message:
        "Map.#{map_func}() materializes all #{map_func} into a list, then counts — use map_size/1 instead",
      why:
        "Map.#{map_func}/1 creates a list of all #{map_func} (O(n) time and memory), then " <>
          "length/1 traverses that list (another O(n)). map_size/1 returns the count " <>
          "in O(1) directly from the map's internal metadata.",
      alternatives: [
        Fix.new(
          summary: "Use map_size/1 instead",
          detail:
            "`Map.#{map_func}(m) |> length()` -> `map_size(m)`\n" <>
              "`length(Map.#{map_func}(m))` -> `map_size(m)`",
          applies_when: "You only need the count, not the actual keys or values list."
        )
      ],
      tags: [:perf],
      file: file,
      line: line
    )
  end
end
