defmodule Archdo.Rules.Module.ZipMapAsZipWith do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.65"

  @impl true
  def description,
    do: "`Enum.zip |> Enum.map(fn {x, y} -> ... end)` — use Enum.zip_with/3 instead"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    Enum.map(AST.find_all(ast, &zip_then_map?/1), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta))
    end)
  end

  # Pipeline `Enum.zip(a, b) |> Enum.map(fn ... end)`. AST shape:
  # `{:|>, _, [zip_call, map_call]}`.
  defp zip_then_map?({:|>, _, [lhs, rhs]}) do
    enum_call?(lhs, :zip) and enum_call?(rhs, :map)
  end

  defp zip_then_map?(_), do: false

  defp enum_call?({{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, args}, target)
       when is_list(args),
       do: fun == target

  defp enum_call?(_, _), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.65",
      title: "Enum.zip + Enum.map — use Enum.zip_with/3",
      message:
        "`Enum.zip(a, b) |> Enum.map(fn {x, y} -> f.(x, y) end)` traverses the data twice " <>
          "and constructs an intermediate list of pairs. `Enum.zip_with/3` does both in one " <>
          "pass and reads more directly.",
      why:
        "`Enum.zip_with/3` (added in Elixir 1.12) was designed exactly for combining elements " <>
          "from parallel collections. The zip-then-map form predates `zip_with/3` and tends " <>
          "to be reached for from habit. The single-pass form has lower allocation cost on " <>
          "large lists and shorter notation for the common case.",
      alternatives: [
        Fix.new(
          summary: "Replace with Enum.zip_with/3",
          detail: "Enum.zip_with(xs, ys, fn x, y -> x + y end)",
          applies_when: "When the map step's anonymous function destructures the zip pair."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.2"],
      context: %{},
      file: file,
      line: line
    )
  end
end
