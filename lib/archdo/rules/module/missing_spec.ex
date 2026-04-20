defmodule Archdo.Rules.Module.MissingSpec do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "2.2"

  @impl true
  def description, do: "Public functions in documented modules must have @spec"

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
        {:defmodule, _meta, [{:__aliases__, _, aliases}, [do: body]]} = node, acc ->
          module_name = Module.concat(aliases)

          if has_moduledoc_false?(body) do
            {node, acc}
          else
            diagnostics = check_public_functions(file, body, module_name)
            {node, diagnostics ++ acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(results)
  end

  defp check_public_functions(file, body, module_name) do
    specs = collect_specs(body)
    public_fns = collect_public_functions(body)

    public_fns
    |> Enum.reject(fn {name, arity, _meta} ->
      # Skip if it has a spec, is a callback impl, or is a defdelegate
      MapSet.member?(specs, {name, arity}) or
        impl?(body, name) or
        defdelegate?(body, name)
    end)
    |> Enum.map(fn {name, arity, meta} ->
      module_str = AST.module_name(module_name)

      Diagnostic.warning("2.2",
        title: "Public function without @spec",
        message: "#{module_str}.#{name}/#{arity} is public but has no @spec",
        why:
          "Public functions form the contract of a module's API. Without `@spec`, callers have no " <>
            "machine-checkable description of what the function takes or returns, Dialyzer can't validate " <>
            "call sites, IDE help is reduced to a name, and signature changes break callers silently. The " <>
            "module is documented (no `@moduledoc false`), so it claims to be public — make the contract explicit.",
        alternatives: [
          Fix.new(
            summary: "Add an `@spec` describing the function's signature",
            detail:
              "Write the spec immediately above the function. Use the most specific types you can — `t()` " <>
                "for the module's struct, `String.t()` rather than `String.t() | nil` unless nil is really valid.",
            example: """
            ```elixir
            @spec #{name}(#{spec_args(arity)}) :: term()
            def #{name}(#{spec_args(arity)}) do
              # ...
            end
            ```
            """,
            applies_when: "The function is part of the supported API."
          ),
          Fix.new(
            summary: "Make the function private (`defp`) if it isn't really public",
            detail:
              "If the function only exists for internal use, change `def` to `defp` and the rule no longer fires. " <>
                "Bonus: Dialyzer and the compiler can give you better warnings about unused private functions.",
            applies_when: "The function was accidentally exposed."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#2.2"],
        context: %{function: "#{module_str}.#{name}/#{arity}"},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp collect_specs(body) do
    {_, specs} =
      Macro.prewalk(body, MapSet.new(), fn
        {:@, _, [{:spec, _, [{:"::", _, [{name, _, args} | _]}]}]} = node, acc
        when is_atom(name) ->
          arity = length(args || [])
          {node, MapSet.put(acc, {name, arity})}

        # Handle when clause in spec
        {:@, _, [{:spec, _, [{:when, _, [{:"::", _, [{name, _, args} | _]} | _]}]}]} = node, acc
        when is_atom(name) ->
          arity = length(args || [])
          {node, MapSet.put(acc, {name, arity})}

        node, acc ->
          {node, acc}
      end)

    specs
  end

  defp collect_public_functions(body) do
    {_, fns} =
      Macro.prewalk(body, [], fn
        {:def, meta, [{name, _, args} | _]} = node, acc when is_atom(name) ->
          arity = length(args || [])
          {node, [{name, arity, meta} | acc]}

        node, acc ->
          {node, acc}
      end)

    fns
    |> Enum.reverse()
    |> Enum.uniq_by(fn {name, arity, _} -> {name, arity} end)
  end

  defp impl?(body, _name) do
    # Check if @impl true appears (covers all callback implementations)
    AST.contains?(body, fn
      {:@, _, [{:impl, _, [true]}]} -> true
      {:@, _, [{:impl, _, [{:__aliases__, _, _}]}]} -> true
      _ -> false
    end)
  end

  defp defdelegate?(body, name) do
    AST.contains?(body, fn
      {:defdelegate, _, [{^name, _, _} | _]} -> true
      _ -> false
    end)
  end

  defp has_moduledoc_false?(body), do: AST.internal_module?(body)

  defp spec_args(0), do: ""
  defp spec_args(n), do: Enum.map_join(1..n, ", ", fn _ -> "term()" end)

end
