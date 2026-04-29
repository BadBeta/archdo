defmodule Archdo.Rules.Module.LongParameterList do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.43"

  @impl true
  def description,
    do: "Public function with 5+ parameters — consider a map, keyword list, or struct"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_long_params(file, ast)
    end
  end

  defp find_long_params(file, ast) do
    # Behaviour callbacks (`@impl true` defs) and protocol implementations
    # (`def`s inside `defimpl`) have arity FIXED by the behaviour/protocol
    # contract. The implementer can't shorten the parameter list. Exempt
    # them. BUG-11 from otel: `should_sample/7` (an OtelApi.Sampler @impl)
    # was flagged on every implementation. Same shape as 6.10's exemption.
    impl_set = AST.impl_callbacks(ast)
    defimpl_set = AST.defimpl_callbacks(ast)

    ast
    |> AST.extract_functions(:public)
    |> Enum.flat_map(fn {name, arity, meta, _args, _body} ->
      cond do
        generated?(name) ->
          []

        MapSet.member?(impl_set, {name, arity}) or
            MapSet.member?(defimpl_set, {name, arity}) ->
          []

        arity >= 7 ->
          [build_diagnostic(file, AST.line(meta), name, arity, :warning)]

        arity >= 5 ->
          # M12: 5-6 params is take-it-or-leave-it — extracting a struct
          # is one of several valid choices; some callers prefer the
          # explicit positional form. Arity 7+ stays :warning.
          [build_diagnostic(file, AST.line(meta), name, arity, :nitpick)]

        true ->
          []
      end
    end)
  end

  defp generated?(name) when is_atom(name) do
    name_str = Atom.to_string(name)
    String.starts_with?(name_str, "__") and String.ends_with?(name_str, "__")
  end

  # Metaprogrammed function names (unquote, etc.) — skip
  defp generated?(_), do: true

  defp build_diagnostic(file, line, name, arity, severity) do
    builder = Diagnostic.builder_for(severity)

    builder.("6.43",
      title: "Long parameter list: #{name}/#{arity}",
      message:
        "#{name}/#{arity} has #{arity} parameters — functions with 5+ params are hard to call correctly",
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
