defmodule Archdo.Rules.OTP.RegistryDynSupOneForOne do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "5.66"

  @impl true
  def description,
    do:
      "Registry + DynamicSupervisor under `:one_for_one` — Registry crash leaves " <>
        "DynSup workers orphaned; use `:rest_for_one` or `:one_for_all`"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {:def, _, [head, kw_or_body]} = node, acc -> {node, scan_def(head, kw_or_body, acc)}
        node, acc -> {node, acc}
      end)

    Enum.map(hits, fn line -> build_diagnostic(file, line) end)
  end

  # For each def, scan the body for the violation: presence of a
  # `Supervisor.init(_, strategy: :one_for_one)` call AND a list
  # literal containing both Registry and DynamicSupervisor child
  # specs. If both appear in the same body, fire.
  defp scan_def(_head, kw_or_body, acc) do
    body = extract_body(kw_or_body)

    case violation_in_body(body) do
      nil -> acc
      line -> [line | acc]
    end
  end

  defp extract_body(kw) when is_list(kw) do
    case Unwrap.kw_get(kw, :do) do
      {:ok, body} -> body
      :error -> nil
    end
  end

  defp extract_body(body), do: body

  defp violation_in_body(nil), do: nil

  defp violation_in_body(body) do
    case {find_one_for_one_init(body), find_registry_dynsup_list(body)} do
      {nil, _} -> nil
      {_, nil} -> nil
      {init_line, _list_line} -> init_line
    end
  end

  defp find_one_for_one_init(body) do
    {_, line} =
      Macro.prewalk(body, nil, fn
        {{:., _, [{:__aliases__, _, [:Supervisor]}, :init]}, meta, [_, opts]} = node, nil ->
          case strategy_atom(opts) do
            :one_for_one -> {node, AST.line(meta)}
            _ -> {node, nil}
          end

        node, acc ->
          {node, acc}
      end)

    line
  end

  defp find_registry_dynsup_list(body) do
    {_, line} =
      Macro.prewalk(body, nil, fn
        list, nil when is_list(list) ->
          case contains_registry_and_dynsup?(list) do
            true -> {list, 1}
            false -> {list, nil}
          end

        node, acc ->
          {node, acc}
      end)

    line
  end

  defp strategy_atom(opts) when is_list(opts) do
    Enum.find_value(opts, fn
      {:strategy, atom} when is_atom(atom) -> atom
      {{:__block__, _, [:strategy]}, atom} when is_atom(atom) -> atom
      {{:__block__, _, [:strategy]}, {:__block__, _, [atom]}} when is_atom(atom) -> atom
      _ -> nil
    end)
  end

  defp strategy_atom(_), do: nil

  defp contains_registry_and_dynsup?(children) when is_list(children) do
    has_registry?(children) and has_dyn_sup?(children)
  end

  defp contains_registry_and_dynsup?(_), do: false

  defp has_registry?(children),
    do: Enum.any?(children, &child_alias_matches?(&1, [:Registry]))

  defp has_dyn_sup?(children),
    do: Enum.any?(children, &child_alias_matches?(&1, [:DynamicSupervisor]))

  # Child specs come in many shapes: `Module`, `{Module, opts}`,
  # `%{id: ..., start: ...}`. Match any of those whose key alias
  # equals the target.
  defp child_alias_matches?({:__aliases__, _, parts}, target), do: parts == target

  defp child_alias_matches?({{:__aliases__, _, parts}, _opts}, target),
    do: parts == target

  defp child_alias_matches?(_, _), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("5.66",
      title:
        "Registry + DynamicSupervisor under `:one_for_one` — workers orphaned on Registry crash",
      message:
        "This Supervisor's children include both Registry and DynamicSupervisor under " <>
          "`strategy: :one_for_one`. If Registry crashes, the DynamicSupervisor's children " <>
          "lose their registrations and can no longer be looked up — orphaned but still " <>
          "running. Use `:rest_for_one` (Registry first) or wrap them in a sub-supervisor " <>
          "with `:one_for_all`.",
      why:
        "`:one_for_one` restarts only the crashed child. When Registry crashes, the " <>
          "Registry process restarts BUT the existing DynamicSupervisor children still hold " <>
          "stale via-tuples that no longer resolve. Lookups fail; new children can't " <>
          "register because old keys collide. The system enters a half-broken state visible " <>
          "only at runtime.",
      alternatives: [
        Fix.new(
          summary: "Use `:rest_for_one` with Registry FIRST",
          detail:
            "children = [\n" <>
              "  {Registry, keys: :unique, name: MyApp.Registry},\n" <>
              "  {DynamicSupervisor, name: MyApp.DynSup}\n" <>
              "]\nSupervisor.init(children, strategy: :rest_for_one)\n" <>
              "# Registry crash → DynSup also restarts → no orphan workers.",
          applies_when: "When the supervisor's other children don't depend on Registry/DynSup."
        ),
        Fix.new(
          summary: "Or wrap Registry + DynSup in a dedicated sub-supervisor with `:one_for_all`",
          detail:
            "Tightly-coupled subsystems: a Fleet.Supervisor with strategy: :one_for_all\n" <>
              "containing exactly those two children, then THAT supervisor as a child of\n" <>
              "the application supervisor.",
          applies_when: "When the supervisor has many other unrelated children."
        )
      ],
      references: ["elixir-implementing/SKILL.md#9.7", "elixir-implementing/SKILL.md#7.9"],
      context: %{},
      file: file,
      line: line
    )
  end
end
