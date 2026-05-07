defmodule Archdo.Rules.Module.DocFalseShouldBeDefp do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "6.87"

  @impl true
  def description,
    do: "`@doc false` on a `def` — the function is still callable. Use `defp` for true privacy."

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    {_, all_block_stmts} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [_alias, kw]} = node, acc when is_list(kw) ->
          case Unwrap.kw_get(kw, :do) do
            {:ok, body} -> {node, [block_stmts(body) | acc]}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.flat_map(all_block_stmts, fn stmts ->
      ctx = %{
        documented_names: collect_documented_names(stmts),
        behaviour_callback_names: collect_behaviour_callback_names(stmts)
      }

      scan_block(stmts, file, ctx)
    end)
  end

  # Collect function names that have AT LEAST ONE real `@doc` in this
  # module body — used to suppress 6.87 on overload-with-shared-docs:
  # `@doc false` `def insert/2` is fine if `def insert/3` has the
  # canonical `@doc """..."""`.
  defp collect_documented_names(stmts) do
    {names, _} =
      Enum.reduce(stmts, {MapSet.new(), :no_doc}, fn stmt, {names, doc_state} ->
        case classify_stmt(stmt) do
          {:doc, :real} -> {names, :real_doc}
          :doc_false -> {names, :no_doc}
          {:def, _, name} when doc_state == :real_doc -> {MapSet.put(names, name), :no_doc}
          {:def, _, _} -> {names, :no_doc}
          {:defp, _, _} -> {names, :no_doc}
          :other -> {names, doc_state}
        end
      end)

    names
  end

  # Collect names of well-known framework behaviour callbacks if this
  # module uses one of those behaviours. The framework dispatches to
  # them via apply/3 — they MUST be public; defp would break the
  # framework. `@doc false` on them just hides them from generated docs.
  defp collect_behaviour_callback_names(stmts) do
    behaviours_used =
      stmts
      |> Enum.flat_map(&extract_behaviour_uses/1)
      |> MapSet.new()

    behaviours_used
    |> Enum.flat_map(&framework_callbacks/1)
    |> MapSet.new()
  end

  # `use Module` / `@behaviour Module` declarations.
  defp extract_behaviour_uses({:use, _, [{:__aliases__, _, parts} | _]}) when is_list(parts) do
    [Enum.join(Enum.map(parts, &Atom.to_string/1), ".")]
  end

  defp extract_behaviour_uses({:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]})
       when is_list(parts) do
    [Enum.join(Enum.map(parts, &Atom.to_string/1), ".")]
  end

  defp extract_behaviour_uses(_), do: []

  # Well-known framework callbacks — when the module declares the
  # corresponding behaviour, these names are dispatched via apply/3
  # and must remain `def`. Listing names without arity because some
  # callbacks have multiple arities (init/1, init/2) and the rule
  # operates at name level.
  defp framework_callbacks("Application"),
    do: ~w(start stop config_change prep_stop start_phase)a

  defp framework_callbacks("Supervisor"), do: ~w(child_spec init start_link)a

  defp framework_callbacks("GenServer"),
    do:
      ~w(init handle_call handle_cast handle_info handle_continue terminate code_change format_status child_spec start_link)a

  defp framework_callbacks("Agent"), do: ~w(child_spec start_link)a
  defp framework_callbacks("Task"), do: ~w(child_spec start_link run)a

  defp framework_callbacks("GenStage"),
    do:
      ~w(init handle_demand handle_subscribe handle_cancel handle_call handle_cast handle_info terminate code_change format_status child_spec)a

  defp framework_callbacks("Plug"), do: ~w(init call)a
  defp framework_callbacks("Plug.Builder"), do: ~w(init call)a
  defp framework_callbacks("Plug.Router"), do: ~w(init call match)a
  defp framework_callbacks("Phoenix.Endpoint"), do: ~w(init call child_spec start_link)a
  defp framework_callbacks("Phoenix.Router"), do: ~w(init call match)a
  defp framework_callbacks("Phoenix.Controller"), do: ~w(init call action)a

  defp framework_callbacks("Phoenix.LiveView"),
    do:
      ~w(mount handle_params handle_event handle_info handle_call handle_cast handle_continue render terminate)a

  defp framework_callbacks("Phoenix.Channel"),
    do: ~w(join handle_in handle_out handle_info terminate)a

  defp framework_callbacks("Oban.Worker"), do: ~w(perform timeout backoff)a

  defp framework_callbacks("Ecto.Repo"),
    do: ~w(init child_spec start_link stop default_options)a

  defp framework_callbacks(_), do: []

  defp block_stmts({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp block_stmts(single), do: [single]

  # Walk the module body's statements; flag any `def` whose preceding
  # statements (since the previous `def`/`defp`) include `@doc false`.
  # Fold across stmts tracking the most recent doc marker.
  defp scan_block(stmts, file, ctx) do
    {hits, _state} =
      Enum.reduce(stmts, {[], :no_doc}, fn stmt, {acc, doc_state} ->
        case classify_stmt(stmt) do
          {:doc, :real} ->
            {acc, :no_doc}

          :doc_false ->
            {acc, :doc_false}

          {:def, line, name} when doc_state == :doc_false ->
            case suppress?(name, ctx) do
              true -> {acc, :no_doc}
              false -> {[line | acc], :no_doc}
            end

          {:def, _, _} ->
            {acc, :no_doc}

          {:defp, _, _} ->
            {acc, :no_doc}

          :other ->
            {acc, doc_state}
        end
      end)

    Enum.map(hits, fn line -> build_diagnostic(file, line) end)
  end

  # Three suppression classes:
  #   1. `__name__/arity` — established Elixir cross-module-internal idiom
  #   2. Framework behaviour callback (child_spec, init, perform, etc.)
  #   3. Overload-with-shared-docs — same name has another arity with real `@doc`
  defp suppress?(name, ctx) do
    cross_module_internal_convention?(name) or
      MapSet.member?(ctx.behaviour_callback_names, name) or
      MapSet.member?(ctx.documented_names, name)
  end

  defp classify_stmt({:@, _, [{:doc, _, [false]}]}), do: :doc_false

  defp classify_stmt({:@, _, [{:doc, _, [{:__block__, _, [false]}]}]}), do: :doc_false

  defp classify_stmt({:@, _, [{:doc, _, [{:__block__, _, [bin]}]}]}) when is_binary(bin),
    do: {:doc, :real}

  defp classify_stmt({:@, _, [{:doc, _, [bin]}]}) when is_binary(bin), do: {:doc, :real}

  defp classify_stmt({:def, meta, [head | _]}), do: {:def, AST.line(meta), def_name(head)}
  defp classify_stmt({:def, meta, _}), do: {:def, AST.line(meta), nil}

  defp classify_stmt({:defp, meta, [head | _]}),
    do: {:defp, AST.line(meta), def_name(head)}

  defp classify_stmt({:defp, meta, _}), do: {:defp, AST.line(meta), nil}
  defp classify_stmt(_), do: :other

  # Extract the function name atom from a def/defp head.
  # Handles `def name(args)`, `def name(args) when guard`, and the
  # zero-arg `def name`.
  defp def_name({:when, _, [{name, _, _} | _]}) when is_atom(name), do: name
  defp def_name({name, _, _}) when is_atom(name), do: name
  defp def_name(_), do: nil

  # `__name__/arity` (double-underscore prefix AND suffix on the name) is
  # the established "public-but-internal" Elixir convention: public so
  # cross-module callers in the same project can use it, `@doc false` to
  # hide from docs. Examples: Phoenix.__init__/2, Plug.Conn.__protocol__/1,
  # Module.__info__/1. The rule's "use defp instead" advice is wrong here
  # — defp would break the cross-module callers that the convention is
  # designed to permit.
  defp cross_module_internal_convention?(name) when is_atom(name) do
    str = Atom.to_string(name)
    String.starts_with?(str, "__") and String.ends_with?(str, "__")
  end

  defp cross_module_internal_convention?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.87",
      title: "`@doc false` on a `def` — should be `defp`",
      message:
        "This function is marked `@doc false` (intent: hide from docs) but defined as " <>
          "`def`, so it's still part of the public API and external callers can invoke it. " <>
          "If the function is truly internal, use `defp`.",
      why:
        "`@doc false` only affects documentation generation; it does NOT change the " <>
          "function's visibility. Other modules can still call it; tools like `mix xref` " <>
          "see it as part of the public surface. `defp` is the actual private-function " <>
          "mechanism — the function isn't exported and can't be called from outside.",
      alternatives: [
        Fix.new(
          summary: "Use `defp` for actual privacy",
          detail:
            "defp internal_helper(x), do: x + 1\n" <>
              "# vs\n" <>
              "@doc false\n" <>
              "def internal_helper(x), do: x + 1",
          applies_when: "When the function is genuinely internal."
        ),
        Fix.new(
          summary: "Or keep `@doc false` if the function MUST stay public (e.g., used by macros)",
          detail:
            "Document why explicitly: `@doc \"Public for macro expansion; not part of API.\"`\n" <>
              "Mark internal use cases. The `@doc false` form is acceptable when:\n" <>
              "- A macro expands to a call to this function in user code.\n" <>
              "- A protocol implementation calls it (must be public).\n" <>
              "- An umbrella sibling needs to call it.",
          applies_when:
            "When the function is genuinely public (in the export sense) but undocumented."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.8"],
      context: %{},
      file: file,
      line: line
    )
  end
end
