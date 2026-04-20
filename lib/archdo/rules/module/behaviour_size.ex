defmodule Archdo.Rules.Module.BehaviourSize do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @max_required_callbacks 5

  @impl true
  def id, do: "4.1"

  @impl true
  def description, do: "Behaviours should have focused interfaces (max #{@max_required_callbacks} required callbacks)"

  @impl true
  def analyze(file, ast, _opts) do
    find_large_behaviours(file, ast)
  end

  defp find_large_behaviours(file, ast) do
    {callbacks, optional} = collect_callbacks(ast)

    required = MapSet.difference(callbacks, optional)
    count = MapSet.size(required)

    if count > @max_required_callbacks do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.info("4.1",
          title: "Behaviour with too many required callbacks",
          message:
            "#{module_name} defines #{count} required callbacks (threshold: #{@max_required_callbacks})",
          why:
            "A behaviour is a contract every implementation must satisfy. Each required callback is a tax on " <>
              "implementers — they have to provide it even if their use case doesn't need it. Large behaviours " <>
              "violate the Interface Segregation Principle: implementations end up writing no-op stubs and the " <>
              "behaviour stops describing a coherent role.",
          alternatives: [
            Fix.new(
              summary: "Split into smaller, role-focused behaviours",
              detail:
                "Group the callbacks by which implementations actually need them and break the behaviour into " <>
                  "two or three smaller behaviours. Each implementation `@behaviour`s only the ones it cares about.",
              applies_when: "The callbacks cluster into distinct responsibilities."
            ),
            Fix.new(
              summary: "Mark rarely-used callbacks as `@optional_callbacks`",
              detail:
                "If most implementations don't need every callback, declare them with " <>
                  "`@optional_callbacks fn1: 0, fn2: 1`. The compiler stops complaining about missing " <>
                  "implementations and the contract becomes 'these you must implement, the rest you may'.",
              applies_when: "Most callbacks are used by some implementations but not all."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#4.1"],
          context: %{module: module_name, callback_count: count, threshold: @max_required_callbacks},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp collect_callbacks(ast) do
    {_, {callbacks, optional}} =
      Macro.prewalk(ast, {MapSet.new(), MapSet.new()}, fn
        {:@, _, [{:callback, _, [{:"::", _, [{name, _, args} | _]}]}]} = node, {cbs, opt}
        when is_atom(name) ->
          arity = length(args || [])
          {node, {MapSet.put(cbs, {name, arity}), opt}}

        {:@, _, [{:callback, _, [{:when, _, [{:"::", _, [{name, _, args} | _]} | _]}]}]} = node, {cbs, opt}
        when is_atom(name) ->
          arity = length(args || [])
          {node, {MapSet.put(cbs, {name, arity}), opt}}

        {:@, _, [{:optional_callbacks, _, [opts]}]} = node, {cbs, opt} when is_list(opts) ->
          new_opt =
            Enum.reduce(opts, opt, fn
              {name, arity}, acc when is_atom(name) and is_integer(arity) ->
                MapSet.put(acc, {name, arity})

              {{:__block__, _, [name]}, {:__block__, _, [arity]}}, acc
              when is_atom(name) and is_integer(arity) ->
                MapSet.put(acc, {name, arity})

              _, acc ->
                acc
            end)

          {node, {cbs, new_opt}}

        node, acc ->
          {node, acc}
      end)

    {callbacks, optional}
  end

end
