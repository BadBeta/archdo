defmodule Archdo.Rules.Module.ModuleCohesion do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @warn_threshold 20
  @error_threshold 40

  @impl true
  def id, do: "6.1"

  @impl true
  def description, do: "Module cohesion — public function count limit"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      check_modules(file, ast)
    end
  end

  defp check_modules(file, ast) do
    {_, results} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [{:__aliases__, _, aliases}, [do: body]]} = node, acc ->
          module_name = AST.module_name(Module.concat(aliases))
          count = count_public_functions(body)
          delegate_count = count_delegates(body)

          # Subtract delegates — facade modules are expected to have many
          effective_count = count - delegate_count

          diagnostics =
            check_count(file, module_name, effective_count, count, delegate_count, AST.line(meta))

          {node, diagnostics ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(results)
  end

  defp count_public_functions(body) do
    {_, count} =
      Macro.prewalk(body, MapSet.new(), fn
        {:def, _, [{name, _, args} | _]} = node, acc when is_atom(name) ->
          arity = length(args || [])
          {node, MapSet.put(acc, {name, arity})}

        node, acc ->
          {node, acc}
      end)

    MapSet.size(count)
  end

  defp count_delegates(body) do
    {_, count} =
      Macro.prewalk(body, 0, fn
        {:defdelegate, _, _} = node, acc -> {node, acc + 1}
        node, acc -> {node, acc}
      end)

    count
  end

  defp check_count(file, module_name, effective_count, total_count, delegate_count, line) do
    suffix = if delegate_count > 0, do: " (#{delegate_count} are delegates)", else: ""

    cond do
      effective_count >= @error_threshold ->
        [cohesion_diag(:error, file, module_name, total_count, suffix, line, effective_count)]

      effective_count >= @warn_threshold ->
        [cohesion_diag(:warning, file, module_name, total_count, suffix, line, effective_count)]

      true ->
        []
    end
  end

  defp cohesion_diag(severity, file, module_name, total_count, suffix, line, effective_count) do
    builder = Diagnostic.builder_for(severity)

    builder.("6.1",
      title: "Module with too many public functions",
      message: "#{module_name} has #{total_count} public functions#{suffix}",
      why:
        "A module with 20+ public functions usually contains multiple responsibilities glued together. " <>
          "Each function is a reason to change, and a wide public API forces every consumer to look at " <>
          "everything. Cohesion drops, navigation gets harder, and the module starts to function as a " <>
          "namespace rather than a coherent unit.",
      alternatives: [
        Fix.new(
          summary: "Split into focused sub-modules with the current module as a facade",
          detail:
            "Group related functions by responsibility and extract each cluster into its own module. The " <>
              "current module can keep a small set of `defdelegate` calls so external callers don't have to " <>
              "be updated immediately. Once the new modules are stable, drop the facade.",
          applies_when: "The functions cluster into 2-5 distinct responsibilities."
        ),
        Fix.new(
          summary: "Accept the count if the module is a deliberate facade",
          detail:
            "If most of the functions are `defdelegate` calls aggregating sub-modules, that's the intended " <>
              "facade pattern. The rule subtracts delegates from the count, but if you're still over the " <>
              "threshold and the module is genuinely a facade, add to freeze.",
          applies_when: "The module already follows the facade pattern."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.1"],
      context: %{
        module: module_name,
        public_functions: total_count,
        effective: effective_count,
        threshold_warn: @warn_threshold,
        threshold_error: @error_threshold
      },
      file: file,
      line: line
    )
  end
end
