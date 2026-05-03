defmodule Archdo.Rules.StateMachine.ImplicitBooleanState do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "9.3"

  @impl true
  def description, do: "No implicit state via boolean flags"

  @state_suggesting_prefixes ~w(is_ has_ was_)
  @state_suggesting_suffixes ~w(_active _enabled _verified _completed _confirmed
    _published _approved _rejected _suspended _locked _archived _deleted _processed)

  @threshold 3

  @impl true
  def analyze(file, ast, _opts) do
    find_boolean_state_schemas(file, ast)
  end

  defp find_boolean_state_schemas(file, ast) do
    {_, results} =
      Macro.prewalk(ast, [], fn
        {:defmodule, mod_meta, [{:__aliases__, _, aliases}, [do: body]]} = node, acc ->
          {node, prepend_module_diag(acc, file, mod_meta, aliases, body)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(results)
  end

  # §§ elixir-implementing: §2.1 — boolean dispatch via multi-clause head.
  # Two stages: (1) is this module an Ecto schema? (2) does it cross the
  # boolean-fields threshold? Each gates the next via an explicit boolean
  # arg instead of nested if/else inside the prewalker.
  defp prepend_module_diag(acc, file, mod_meta, aliases, body) do
    schema_dispatch(has_ecto_schema?(body), acc, file, mod_meta, aliases, body)
  end

  defp schema_dispatch(false, acc, _file, _mod_meta, _aliases, _body), do: acc

  defp schema_dispatch(true, acc, file, mod_meta, aliases, body) do
    boolean_fields = find_state_booleans(body)
    threshold_dispatch(length(boolean_fields) >= @threshold, acc, file, mod_meta, aliases, boolean_fields)
  end

  defp threshold_dispatch(false, acc, _file, _mod_meta, _aliases, _boolean_fields), do: acc

  defp threshold_dispatch(true, acc, file, mod_meta, aliases, boolean_fields) do
    [build_diagnostic(file, mod_meta, aliases, boolean_fields) | acc]
  end

  defp build_diagnostic(file, mod_meta, aliases, boolean_fields) do
    module_name = AST.module_name(Module.concat(aliases))
    field_names = Enum.map_join(boolean_fields, ", ", fn {name, _} -> ":#{name}" end)

    Diagnostic.info("9.3",
      title: "Implicit state machine via boolean flags",
      message:
        "#{module_name} has #{length(boolean_fields)} state-suggesting boolean fields: #{field_names}",
      why:
        "When an entity has 3+ booleans like `is_active`, `is_verified`, `is_suspended`, the " <>
          "schema implicitly defines a 2^n state machine where most combinations are invalid (e.g. " <>
          "`active=true, suspended=true`). The valid states aren't documented, the invalid ones can " <>
          "be created by mistake, and reasoning about transitions becomes detective work.",
      alternatives: [
        Fix.new(
          summary: "Replace the booleans with a single `:status` enum field",
          detail:
            "Define an enum (`:active`, `:suspended`, `:verified`, etc.) and a `:status` field. " <>
              "Each entity has exactly one status, transitions are explicit functions, and invalid " <>
              "combinations become unrepresentable.",
          applies_when: "The booleans really represent stages of one workflow."
        ),
        Fix.new(
          summary: "Use a state machine library (gen_statem, fsmx, AshStateMachine)",
          detail:
            "If transitions have side effects or guards, use a real state machine library. The " <>
              "valid transitions are declared once, guards run on transition, and the schema only " <>
              "stores the current state.",
          applies_when: "The transitions need guards or side effects."
        ),
        Fix.new(
          summary: "Keep the booleans if they're genuinely independent",
          detail:
            "Sometimes boolean fields are independent capabilities (`can_email`, `can_sms`, " <>
              "`can_push`) rather than states. If every combination is meaningful and there's no " <>
              "implicit state machine, leave them and add to the freeze baseline.",
          applies_when: "The booleans represent independent capabilities, not states."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#9.3"],
      context: %{
        module: module_name,
        boolean_fields: Enum.map(boolean_fields, fn {n, _} -> to_string(n) end)
      },
      file: file,
      line: AST.line(mod_meta)
    )
  end

  defp has_ecto_schema?(body) do
    AST.contains?(body, fn
      {:use, _, [{:__aliases__, _, [:Ecto, :Schema]} | _]} -> true
      {:schema, _, _} -> true
      _ -> false
    end)
  end

  defp find_state_booleans(body) do
    {_, fields} =
      Macro.prewalk(body, [], fn
        {:field, meta, [name, {:__aliases__, _, [:Boolean]} | _]} = node, acc
        when is_atom(name) ->
          if state_suggesting_name?(Atom.to_string(name)) do
            {node, [{name, AST.line(meta)} | acc]}
          else
            {node, acc}
          end

        {:field, meta, [name, :boolean | _]} = node, acc when is_atom(name) ->
          if state_suggesting_name?(Atom.to_string(name)) do
            {node, [{name, AST.line(meta)} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(fields)
  end

  defp state_suggesting_name?(name) do
    Enum.any?(@state_suggesting_prefixes, &String.starts_with?(name, &1)) or
      Enum.any?(@state_suggesting_suffixes, &String.ends_with?(name, &1))
  end
end
