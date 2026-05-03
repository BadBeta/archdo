defmodule Archdo.Rules.Module.InconsistentErrorShape do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # Internal style classification for unrecognized return shapes.
  @unknown_style :unknown

  @impl true
  def id, do: "6.11"

  @impl true
  def description, do: "Module mixes ok/error tuples with raises, nils, and bare returns"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      check_consistency(file, ast)
    end
  end

  defp check_consistency(file, ast) do
    fns = AST.extract_functions(ast, :public)

    # Classify each public function's error handling style
    styles =
      fns
      |> Enum.reject(fn {name, _, _, _, _} -> not is_atom(name) end)
      |> Enum.map(fn {name, arity, _meta, _args, body} ->
        {name, arity, classify_style(body)}
      end)
      |> Enum.reject(fn {_, _, style} -> style == @unknown_style end)

    style_groups =
      styles
      |> Enum.map(fn {_, _, style} -> style end)
      |> Enum.uniq()

    # Flag if a single module uses 3+ different styles, or mixes :ok_error with :raises
    cond do
      length(style_groups) >= 3 ->
        [build_diagnostic(file, ast, styles, style_groups)]

      :ok_error in style_groups and :raises in style_groups ->
        [build_diagnostic(file, ast, styles, style_groups)]

      :ok_error in style_groups and :returns_nil in style_groups ->
        [build_diagnostic(file, ast, styles, style_groups)]

      true ->
        []
    end
  end

  defp classify_style(nil), do: :unknown

  defp classify_style(body) do
    has_ok_error =
      AST.contains?(body, fn
        {:{}, _, [{:__block__, _, [:ok]} | _]} -> true
        {:{}, _, [{:__block__, _, [:error]} | _]} -> true
        {:ok, _} -> true
        {:error, _} -> true
        _ -> false
      end)

    has_raise =
      AST.contains?(body, fn
        {:raise, _, _} -> true
        _ -> false
      end) and
        not AST.contains?(body, fn
          {:rescue, _} -> true
          _ -> false
        end)

    has_nil_return =
      AST.contains?(body, fn
        {:__block__, _, [nil]} -> true
        _ -> false
      end)

    cond do
      has_ok_error -> :ok_error
      has_raise -> :raises
      has_nil_return -> :returns_nil
      true -> :unknown
    end
  end

  defp build_diagnostic(file, ast, styles, style_groups) do
    module_name = AST.extract_module_name(ast)

    raising_fns =
      styles
      |> Enum.filter(fn {_, _, s} -> s == :raises end)
      |> format_fns()

    ok_error_fns =
      styles
      |> Enum.filter(fn {_, _, s} -> s == :ok_error end)
      |> format_fns()

    nil_fns =
      styles
      |> Enum.filter(fn {_, _, s} -> s == :returns_nil end)
      |> format_fns()

    detail_parts =
      [
        if(ok_error_fns != "", do: "ok/error: #{ok_error_fns}"),
        if(raising_fns != "", do: "raises: #{raising_fns}"),
        if(nil_fns != "", do: "returns nil: #{nil_fns}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    Diagnostic.info("6.11",
      title: "Inconsistent error handling in module",
      message: "#{module_name} mixes #{length(style_groups)} error styles: #{detail_parts}",
      why:
        "When a module's public API uses ok/error tuples for some functions and raises for others " <>
          "(without the `!` naming convention), callers can't predict which pattern to use. A `with` " <>
          "chain that works for function A fails on function B because B raises instead of returning " <>
          "{:error, _}. Nil returns are the worst variant: the caller must check for nil, but `with` " <>
          "and pattern matching don't catch it — nil passes through silently and crashes later.",
      alternatives: [
        Fix.new(
          summary: "Standardize on ok/error tuples for the non-bang API",
          detail:
            "Convert functions that raise (#{raising_fns}) to return {:error, reason}. " <>
              "Convert functions that return nil on failure (#{nil_fns}) to return {:error, :not_found}. " <>
              "If callers need the raising variant, add `!`-suffixed versions that wrap the tuple API.",
          example: """
          ```elixir
          # Consistent ok/error API:
          def find(id), do: {:ok, lookup(id)} |> or_not_found()
          def find!(id), do: find(id) |> ok_or_raise!()

          defp or_not_found({:ok, nil}), do: {:error, :not_found}
          defp or_not_found(other), do: other

          defp ok_or_raise!({:ok, result}), do: result
          defp ok_or_raise!({:error, reason}), do: raise "not found: \#{reason}"
          ```
          """,
          applies_when: "The module is a public API called by other modules."
        ),
        Fix.new(
          summary: "Keep raising if the module is a validation/assertion library",
          detail:
            "Some modules are intentionally strict — validators, parsers, and assertion helpers " <>
              "raise because invalid input is a programming error, not a runtime condition. If that's " <>
              "the case, make all functions consistent (all raise), name them with `!`, or document " <>
              "the convention in @moduledoc.",
          applies_when: "The module is a validator or assertion library."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.11"],
      context: %{
        module: module_name,
        styles: Enum.map(style_groups, &Atom.to_string/1),
        raising_functions: raising_fns,
        ok_error_functions: ok_error_fns,
        nil_functions: nil_fns
      },
      file: file,
      line: 1
    )
  end

  defp format_fns(fns) do
    fns
    |> Enum.take(5)
    |> Enum.map_join(", ", fn {name, arity, _} -> "#{name}/#{arity}" end)
  end
end
