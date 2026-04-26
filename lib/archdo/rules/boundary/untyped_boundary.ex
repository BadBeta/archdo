defmodule Archdo.Rules.Boundary.UntypedBoundary do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.12"

  @impl true
  def description,
    do: "Untyped boundaries — context public APIs returning map()/keyword() instead of structs"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or not context_like?(file) do
      []
    else
      find_untyped_specs(file, ast)
    end
  end

  defp find_untyped_specs(file, ast) do
    # Find @spec declarations with untyped returns
    ast
    |> AST.find_all(fn
      {:@, _, [{:spec, _, _}]} -> true
      _ -> false
    end)
    |> Enum.flat_map(fn {:@, meta, [{:spec, _, spec_args}]} ->
      case spec_args do
        [{:"::", _, [_lhs, return_type]}] ->
          if untyped_return?(return_type) do
            fn_name = extract_spec_fn_name(spec_args)

            [
              Diagnostic.info("1.12",
                title: "Untyped public API return",
                message:
                  "#{fn_name}'s @spec returns an untyped map()/keyword()/list() across the context boundary",
                why:
                  "When a public function returns an untyped map, callers can only discover its shape by " <>
                    "reading the source. There is no compile-time check on field names, no IDE help, and " <>
                    "renaming a key silently breaks every consumer. Defining a struct turns those leaks into " <>
                    "discoverable, documented contracts that can evolve safely.",
                alternatives: [
                  Fix.new(
                    summary: "Define a struct for the return type",
                    detail:
                      "Create a small struct (e.g. `defmodule MyApp.Accounts.UserView do defstruct [...] end`) " <>
                        "and return that. The @spec becomes `t :: %UserView{...}`, callers pattern-match on the " <>
                        "struct, and refactors are caught at compile time.",
                    applies_when: "The shape is stable and worth documenting."
                  ),
                  Fix.new(
                    summary: "Use a typespec for the map keys",
                    detail:
                      "If creating a struct is overkill, at least define a `@type t :: %{required(:id) => integer, " <>
                        "required(:name) => String.t()}` so the spec is precise. It's not as good as a struct " <>
                        "but documents the contract.",
                    applies_when: "A struct is too heavyweight for the use case."
                  )
                ],
                references: ["ARCHITECTURE_RULES.md#1.12"],
                context: %{function: fn_name},
                file: file,
                line: AST.line(meta)
              )
            ]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp untyped_return?({:map, _, _}), do: true
  defp untyped_return?({:keyword, _, _}), do: true
  defp untyped_return?({:list, _, _}), do: true
  # {:ok, map()} | {:error, atom()}
  defp untyped_return?({:|, _, branches}) do
    Enum.any?(branches, fn
      {:{}, _, [{:__block__, _, [:ok]}, {:map, _, _}]} -> true
      {:ok, {:map, _, _}} -> true
      _ -> false
    end)
  end

  defp untyped_return?(_), do: false

  defp extract_spec_fn_name([{:"::", _, [{name, _, _} | _]}]) when is_atom(name) do
    Atom.to_string(name)
  end

  defp extract_spec_fn_name(_), do: "(spec)"

  defp context_like?(file) do
    # Top-level context module (directly under lib/app_name/)
    case String.split(file, "/lib/") do
      [_, rest] ->
        parts = String.split(rest, "/")
        length(parts) == 2

      _ ->
        false
    end
  end
end
