defmodule Archdo.Rules.Module.LongParameterList do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.43"

  @impl true
  def description, do: "Public function with 5+ parameters — consider a map, keyword list, or struct"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_long_params(file, ast)
    end
  end

  defp find_long_params(file, ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.flat_map(fn {name, arity, meta, _args, _body} ->
      case {generated?(name), arity} do
        {true, _} -> []
        {false, a} when a >= 7 -> [build_diagnostic(file, AST.line(meta), name, a, :warning)]
        {false, a} when a >= 5 -> [build_diagnostic(file, AST.line(meta), name, a, :info)]
        _ -> []
      end
    end)
  end

  defp generated?(name) do
    name_str = Atom.to_string(name)
    String.starts_with?(name_str, "__") and String.ends_with?(name_str, "__")
  end

  defp build_diagnostic(file, line, name, arity, severity) do
    builder = Diagnostic.builder_for(severity)

    builder.("6.43",
      title: "Long parameter list: #{name}/#{arity}",
      message: "#{name}/#{arity} has #{arity} parameters — functions with 5+ params are hard to call correctly",
      why:
        "Long parameter lists make call sites fragile (easy to swap arguments) " <>
          "and hard to extend. Group related parameters into a map, keyword list, " <>
          "or struct to improve readability and maintainability.",
      alternatives: [
        Fix.new(
          summary: "Accept a map or keyword list instead",
          detail:
            "Replace positional parameters with `def #{name}(opts)` where opts " <>
              "is a keyword list or map with named keys.",
          applies_when: "Parameters are configuration-like or rarely all provided together."
        ),
        Fix.new(
          summary: "Introduce a struct to group related parameters",
          detail:
            "If the parameters represent a coherent concept, define a struct " <>
              "and pass it as a single argument.",
          applies_when: "Parameters are always used together and represent a domain concept."
        )
      ],
      file: file,
      line: line
    )
  end
end
