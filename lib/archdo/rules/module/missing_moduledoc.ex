defmodule Archdo.Rules.Module.MissingModuledoc do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "2.1"

  @impl true
  def description, do: "Every module must have @moduledoc"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_modules_without_moduledoc(file, ast)
    end
  end

  defp find_modules_without_moduledoc(file, ast) do
    {_, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [{:__aliases__, _, aliases}, [do: body]]} = node, acc ->
          module_name = Module.concat(aliases)

          if has_moduledoc?(body) or protocol_impl?(body) or mix_task?(module_name) do
            {node, acc}
          else
            {node, [{module_name, AST.line(meta)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    modules
    |> Enum.reverse()
    |> Enum.map(fn {module_name, line} ->
      Diagnostic.info("2.1",
        title: "Module without @moduledoc",
        message: "#{module_name} has no @moduledoc declaration",
        why:
          "@moduledoc serves as the public/private flag for a module. Without it, callers can't tell whether " <>
            "the module is part of the supported API or an internal helper. Tools like ExDoc skip undocumented " <>
            "modules silently, and refactors that rename or move them break consumers who shouldn't have been " <>
            "using them in the first place.",
        alternatives: [
          Fix.new(
            summary: "Add `@moduledoc \"...\"` describing the public API",
            detail:
              "Document what the module is for, who is supposed to call it, and what the canonical entry " <>
                "points are. ExDoc picks it up automatically and the module is signposted as public.",
            applies_when: "The module is part of the supported public API."
          ),
          Fix.new(
            summary: "Add `@moduledoc false` if the module is internal",
            detail:
              "Mark internal helpers and implementation modules with `@moduledoc false`. The intent is " <>
                "explicit, ExDoc skips them, and rule 2.3 (PrivateModuleCalls) can flag external callers " <>
                "that reach in.",
            applies_when: "The module is an internal helper not meant for external callers."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#2.1"],
        context: %{module: to_string(module_name) |> String.replace_leading("Elixir.", "")},
        file: file,
        line: line
      )
    end)
  end

  defp has_moduledoc?(body) do
    AST.contains?(body, fn
      {:@, _, [{:moduledoc, _, _}]} -> true
      _ -> false
    end)
  end

  defp protocol_impl?(body) do
    AST.contains?(body, fn
      {:defimpl, _, _} -> true
      {:@, _, [{:impl, _, [true]}]} -> true
      _ -> false
    end)
  end

  defp mix_task?(module_name) do
    module_name
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Mix.Tasks.")
  end

end
