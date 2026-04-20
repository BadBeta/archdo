defmodule Archdo.Rules.Compiled.DegenerateFunction do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled.Graph

  @impl true
  def id, do: "6.30"

  @impl true
  def description, do: "Public function always raises or returns a fixed value — likely a stub"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @spec analyze_compiled(Graph.t()) :: [Diagnostic.t()]
  def analyze_compiled(%Graph{beam_dir: beam_dir}) when is_binary(beam_dir) do
    beam_dir
    |> Path.join("Elixir.*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(fn beam_path ->
      charlist = to_charlist(beam_path)

      case :beam_lib.chunks(charlist, [:abstract_code]) do
        {:ok, {mod, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
          exports = Graph.collect_exports_from_forms(forms)
          find_degenerate(mod, forms, exports)

        _ ->
          []
      end
    end)
  end

  def analyze_compiled(_graph), do: []

  defp find_degenerate(mod, forms, exports) do
    forms
    |> Enum.flat_map(fn
      {:function, _line, name, arity, clauses}
      when name not in [:__info__, :module_info, :__struct__, :__impl__, :__protocol__,
                         :__deriving__, :__using__, :__before_compile__, :__after_compile__,
                         :behaviour_info,
                         # OTP callbacks that normally return fixed atoms
                         :init, :terminate, :code_change, :format_status,
                         :handle_continue, :start_link, :child_spec,
                         :mount, :render, :update] ->
        case MapSet.member?(exports, {name, arity}) do
          true -> check_function(mod, name, arity, clauses)
          false -> []
        end

      _ ->
        []
    end)
  end

  defp check_function(mod, name, arity, clauses) do
    case classify_degenerate(clauses) do
      nil -> []
      kind -> [build_diagnostic(mod, name, arity, kind)]
    end
  end

  defp classify_degenerate(clauses) do
    # Check if ALL clauses have the same degenerate body
    kinds = Enum.map(clauses, &classify_clause_body/1)

    case Enum.uniq(kinds) do
      # Always-raises is a stub regardless of clause count
      [:always_raises] -> :always_raises
      [:not_implemented_raise] -> :not_implemented

      # Fixed atom is only degenerate with multiple clauses
      # (single-clause :ok returns are normal for side-effect functions)
      [:returns_fixed_atom] when length(clauses) > 1 -> :returns_fixed_atom

      _ -> nil
    end
  end

  defp classify_clause_body({:clause, _, _args, _guards, body}) do
    case List.last(body) do
      # raise "message"
      {:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :error}},
       [{:tuple, _, [{:atom, _, exception}, message | _]}]}
      when exception in [RuntimeError, ArgumentError] ->
        case extract_string(message) do
          nil -> :always_raises
          msg ->
            lower = String.downcase(msg)

            cond do
              String.contains?(lower, "not implemented") -> :not_implemented_raise
              String.contains?(lower, "todo") -> :not_implemented_raise
              String.contains?(lower, "not yet") -> :not_implemented_raise
              String.contains?(lower, "stub") -> :not_implemented_raise
              true -> :always_raises
            end
        end

      # Direct erlang:error call (another raise pattern)
      {:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :error}}, _} ->
        :always_raises

      # Returns a fixed atom like :ok, :error, nil
      {:atom, _, _value} ->
        :returns_fixed_atom

      _ ->
        :other
    end
  end

  defp extract_string({:bin, _, [{:bin_element, _, {:string, _, charlist}, _, _}]}) do
    to_string(charlist)
  end

  defp extract_string({:string, _, charlist}), do: to_string(charlist)
  defp extract_string(_), do: nil

  defp build_diagnostic(mod, name, arity, kind) do
    mod_name = AST.module_name(mod)

    {kind_desc, severity_fn} =
      case kind do
        :not_implemented ->
          {"raises \"not implemented\" — this is a stub", &Diagnostic.warning/2}

        :always_raises ->
          {"always raises an exception regardless of input", &Diagnostic.info/2}

        :returns_fixed_atom ->
          {"always returns a fixed atom regardless of input — may be a stub", &Diagnostic.info/2}
      end

    severity_fn.("6.30",
      title: "Degenerate function body",
      message: "#{mod_name}.#{name}/#{arity} #{kind_desc}",
      why:
        "After macro expansion, this function's compiled body is degenerate — " <>
          "it either always raises or always returns the same value. " <>
          "This pattern typically indicates an unfinished stub, a placeholder " <>
          "from code generation, or a function that was gutted during refactoring " <>
          "but not removed. Unlike AST analysis, this check sees the actual code " <>
          "after all macros have expanded.",
      alternatives: [
        Fix.new(
          summary: "Implement the function",
          detail: "Replace the stub body with the actual implementation.",
          applies_when: "The function is meant to do real work."
        ),
        Fix.new(
          summary: "Delete if unused",
          detail:
            "If #{name}/#{arity} is a leftover, remove it. " <>
              "Check rule 6.24 (dead code) — it may already be flagged.",
          applies_when: "The function is not called."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.30"],
      context: %{
        module: mod_name,
        function: "#{name}/#{arity}",
        kind: kind
      },
      file: "lib",
      line: 0
    )
  end

end
