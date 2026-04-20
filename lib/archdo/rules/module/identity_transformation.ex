defmodule Archdo.Rules.Module.IdentityTransformation do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.38"

  @impl true
  def description, do: "Identity transformation — no-op function call that returns its input unchanged"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_identity_transforms(file, ast)
    end
  end

  defp find_identity_transforms(file, ast) do
    List.flatten([
      find_identity_map(file, ast),
      find_always_true_filter(file, ast),
      find_always_false_reject(file, ast),
      find_flatten_single(file, ast)
    ])
  end

  # --- Enum.map(_, fn x -> x end) or Enum.map(_, & &1) ---

  defp find_identity_map(file, ast) do
    AST.find_all(ast, fn
      # Enum.map(_, fn x -> x end)
      {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [_, {:fn, _, [{:->, _, [[{var, _, ctx}], {var, _, ctx}]}]}]}
      when is_atom(var) and is_atom(ctx) ->
        true

      # Enum.map(_, & &1) — the 1 may or may not be wrapped in __block__
      {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [_, {:&, _, [{:&, _, [1]}]}]} ->
        true

      {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [_, {:&, _, [{:&, _, [{:__block__, _, [1]}]}]}]} ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta), :identity_map)
    end)
  end

  # --- Enum.filter(_, fn _ -> true end) ---

  defp find_always_true_filter(file, ast) do
    AST.find_all(ast, fn
      # Enum.filter(_, fn _ -> true end)
      {{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [_, {:fn, _, [{:->, _, [_, true]}]}]} ->
        true

      # Enum.filter(_, fn _ -> true end) with literal_encoder wrapping
      {{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, [_, {:fn, _, [{:->, _, [_, {:__block__, _, [true]}]}]}]} ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta), :always_true_filter)
    end)
  end

  # --- Enum.reject(_, fn _ -> false end) ---

  defp find_always_false_reject(file, ast) do
    AST.find_all(ast, fn
      # Enum.reject(_, fn _ -> false end)
      {{:., _, [{:__aliases__, _, [:Enum]}, :reject]}, _, [_, {:fn, _, [{:->, _, [_, false]}]}]} ->
        true

      # With literal_encoder wrapping
      {{:., _, [{:__aliases__, _, [:Enum]}, :reject]}, _, [_, {:fn, _, [{:->, _, [_, {:__block__, _, [false]}]}]}]} ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta), :always_false_reject)
    end)
  end

  # --- List.flatten([single_item]) ---

  defp find_flatten_single(file, ast) do
    AST.find_all(ast, fn
      # List.flatten([single]) — a list literal with exactly one element
      # The list literal is wrapped in __block__ by the literal_encoder
      {{:., _, [{:__aliases__, _, [:List]}, :flatten]}, _, [{:__block__, _, [[_single]]}]} ->
        true

      # Without literal_encoder wrapping
      {{:., _, [{:__aliases__, _, [:List]}, :flatten]}, _, [[_single]]} ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta), :flatten_single)
    end)
  end

  # --- Diagnostics ---

  defp build_diagnostic(file, line, :identity_map) do
    Diagnostic.info("6.38",
      title: "Identity transformation: Enum.map with identity function",
      message: "Enum.map(_, fn x -> x end) returns its input unchanged — the map call is a no-op",
      why:
        "An identity function inside Enum.map produces a copy of the original list " <>
          "with no transformation. This is wasted computation and obscures intent.",
      alternatives: [
        Fix.new(
          summary: "Remove the Enum.map call entirely",
          detail: "The input already has the desired shape. Just use it directly.",
          applies_when: "The callback returns its argument unchanged."
        )
      ],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :always_true_filter) do
    Diagnostic.info("6.38",
      title: "Identity transformation: Enum.filter with always-true predicate",
      message: "Enum.filter(_, fn _ -> true end) keeps all elements — the filter is a no-op",
      why:
        "A filter that always returns true never removes any elements. " <>
          "This copies the entire list for no reason.",
      alternatives: [
        Fix.new(
          summary: "Remove the Enum.filter call entirely",
          detail: "All elements pass the filter, so the result is the same as the input.",
          applies_when: "The predicate always returns true regardless of input."
        )
      ],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :always_false_reject) do
    Diagnostic.info("6.38",
      title: "Identity transformation: Enum.reject with always-false predicate",
      message: "Enum.reject(_, fn _ -> false end) rejects nothing — the reject is a no-op",
      why:
        "A reject that always returns false never removes any elements. " <>
          "This copies the entire list for no reason.",
      alternatives: [
        Fix.new(
          summary: "Remove the Enum.reject call entirely",
          detail: "No elements are rejected, so the result is the same as the input.",
          applies_when: "The predicate always returns false regardless of input."
        )
      ],
      file: file,
      line: line
    )
  end

  defp build_diagnostic(file, line, :flatten_single) do
    Diagnostic.info("6.38",
      title: "Identity transformation: List.flatten on single-element list",
      message: "List.flatten([x]) — wrapping in a list then flattening is redundant",
      why:
        "Wrapping a value in a list literal and immediately flattening it " <>
          "is a no-op if x is not a list, or equivalent to List.flatten(x) if it is. " <>
          "Either way the wrapping is unnecessary.",
      alternatives: [
        Fix.new(
          summary: "Use the value directly or call List.flatten on it",
          detail:
            "If x is not a list, use `[x]` or `x` directly. " <>
              "If x might be a list, call `List.flatten(x)` without the wrapper.",
          applies_when: "A single element is wrapped in a list literal before flattening."
        )
      ],
      file: file,
      line: line
    )
  end
end
