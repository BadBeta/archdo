defmodule Archdo.Rules.Module.BoundaryAtomStringMismatch do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.75"

  @impl true
  def description,
    do:
      "Controller / LiveView pattern-matches atom keys against external params — " <>
        "Phoenix params arrive as string-keyed maps"

  @def_kws [:def, :defp]

  # Controller action / LV callback names whose 2nd arg is the
  # external params map. Matching atom keys against that arg silently
  # never fires (params keys are strings).
  @action_callbacks [:index, :show, :new, :create, :edit, :update, :delete]
  @lv_callbacks [:mount, :handle_params, :handle_event]

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      not boundary_file?(file, ast) -> []
      true -> find_violations(file, ast)
    end
  end

  defp boundary_file?(file, ast) do
    AST.controller_file?(file) or AST.live_view_file?(file) or
      controller_use?(ast) or AST.uses_live_view?(ast)
  end

  defp controller_use?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, parts} | _]} = node, _acc ->
          {node, parts == [:Phoenix, :Controller] or List.last(parts) == :Controller}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp find_violations(file, ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {def_kw, meta, [head, _kw_or_body]} = node, acc when def_kw in @def_kws ->
          case action_with_atom_keys?(head) do
            true -> {node, [AST.line(meta) | acc]}
            false -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.map(hits, fn line -> build_diagnostic(file, line) end)
  end

  defp action_with_atom_keys?({:when, _, [inner, _guard]}),
    do: action_with_atom_keys?(inner)

  defp action_with_atom_keys?({name, _, args})
       when is_atom(name) and is_list(args) do
    case name in (@action_callbacks ++ @lv_callbacks) and args != [] do
      true -> Enum.any?(args, &has_atom_key_destructure?/1)
      false -> false
    end
  end

  defp action_with_atom_keys?(_), do: false

  # `%{key: val}` destructure with atom keys. Skip empty `%{}` (matches
  # any map; that's a different bug, covered by 6.71). Also skip when
  # ALL keys are strings (`%{"k" => v}` — already correct).
  defp has_atom_key_destructure?({:%{}, _, []}), do: false

  defp has_atom_key_destructure?({:%{}, _, fields}) when is_list(fields) do
    Enum.any?(fields, fn
      {key, _val} when is_atom(key) -> true
      _ -> false
    end)
  end

  defp has_atom_key_destructure?({:=, _, [lhs, rhs]}),
    do: has_atom_key_destructure?(lhs) or has_atom_key_destructure?(rhs)

  defp has_atom_key_destructure?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("6.75",
      title: "Atom-key pattern in controller / LiveView action — params are string-keyed",
      message:
        "This action / callback pattern-matches atom keys (`%{id: id}`) against the " <>
          "external params argument. Phoenix delivers params as a map with string keys; " <>
          "the atom-key pattern silently never matches and the action falls through.",
      why:
        ~s|Atom keys (`:id`) and string keys (`"id"`) are NOT interchangeable in Elixir | <>
          ~s|patterns. Phoenix `params` always arrive as `%{"id" => "42"}`. A pattern of | <>
          ~s|`%{id: id}` matches only if the map happens to contain the literal atom key | <>
          ~s|`:id` — which `params` does not. The action body never runs; the calling | <>
          ~s|framework usually picks up the next clause or falls through to a 404.|,
      alternatives: [
        Fix.new(
          summary: "Use string keys for external params",
          detail:
            "def show(conn, %{\"id\" => id}) do\n" <>
              "  render(conn, :show, id: id)\n" <>
              "end",
          applies_when: "Always for Phoenix controller / LiveView params."
        ),
        Fix.new(
          summary: "Or normalize once at the boundary",
          detail:
            "def show(conn, params) do\n" <>
              "  attrs = MyApp.Params.normalize(params)\n" <>
              "  # internal code now uses atom keys\n" <>
              "end",
          applies_when:
            "When you want internal code to use atom keys but the entry is at this layer."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.3", "elixir-implementing/SKILL.md#7.6"],
      context: %{},
      file: file,
      line: line
    )
  end
end
