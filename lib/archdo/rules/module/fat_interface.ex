defmodule Archdo.Rules.Module.FatInterface do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.21"

  @impl true
  def description,
    do: "Behaviour implementations with no-op stubs suggest the interface should be split"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  # No-op body patterns — these indicate a callback the implementation doesn't need.
  @noop_bodies [
    :ok,
    :noop,
    :ignore,
    nil,
    [],
    false,
    {:__block__, :ok},
    {:__block__, nil}
  ]

  @doc """
  Project-level: find behaviour implementations with stubbed callbacks.
  """
  def analyze_project(file_asts) do
    # Phase 1: collect behaviour definitions and their implementations
    {behaviour_defs, implementations} = index_behaviours(file_asts)

    # Phase 2: for each implementation, find no-op stubs
    impl_stubs =
      for impl <- implementations,
          stubs = find_noop_stubs(impl.ast, impl.behaviours),
          match?([_ | _], stubs),
          do: Map.put(impl, :stubs, stubs)

    # Phase 3: group by behaviour and check if different impls stub different callbacks
    for impl <- impl_stubs,
        bhv <- impl.behaviours,
        bhv_stubs = Enum.filter(impl.stubs, &(&1.likely_from == bhv or &1.likely_from == nil)),
        match?([_ | _], bhv_stubs),
        do: build_diagnostic(impl, bhv, bhv_stubs, behaviour_defs)
  end

  # --- Phase 1: Index ---

  defp index_behaviours(file_asts) do
    Enum.reduce(file_asts, {%{}, []}, fn {file, ast}, {defs, impls} ->
      module_name = AST.extract_module_name(ast)

      # Check if this module defines a behaviour (has @callback)
      defs =
        case AST.contains?(ast, &match?({:@, _, [{:callback, _, _}]}, &1)) do
          true -> Map.put(defs, module_name, %{file: file})
          false -> defs
        end

      # Check if this module implements a behaviour
      impls =
        case extract_behaviour_names(ast) do
          [_ | _] = behaviours ->
            [%{module: module_name, file: file, ast: ast, behaviours: behaviours} | impls]

          [] ->
            impls
        end

      {defs, impls}
    end)
  end

  defp extract_behaviour_names(ast) do
    ast
    |> AST.find_all(fn
      {:@, _, [{:behaviour, _, _}]} -> true
      _ -> false
    end)
    |> Enum.flat_map(fn
      {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]} ->
        [Enum.map_join(parts, ".", &to_string/1)]

      {:@, _, [{:behaviour, _, [atom_bhv]}]} when is_atom(atom_bhv) ->
        [AST.module_name(atom_bhv)]

      _ ->
        []
    end)
  end

  # --- Phase 2: Find no-op stubs ---

  defp find_noop_stubs(ast, _behaviours) do
    # Find all @impl true functions and check if their body is a no-op
    fns = AST.extract_functions(ast, :public)

    # Track which functions have @impl true
    impl_fns = find_impl_functions(ast)

    fns
    |> Enum.filter(fn {name, arity, _meta, _args, body} ->
      MapSet.member?(impl_fns, {name, arity}) and noop_body?(body)
    end)
    |> Enum.map(fn {name, arity, meta, _args, _body} ->
      %{name: name, arity: arity, line: AST.line(meta), likely_from: nil}
    end)
  end

  defp find_impl_functions(ast) do
    # Walk the AST and track @impl true, then the next def gets marked.
    # Use postwalk so we see the @impl attribute before descending into
    # children that would reset the flag.
    {_, {_, impl_fns}} =
      Macro.prewalk(ast, {false, MapSet.new()}, fn
        {:@, _, [{:impl, _, [true]}]} = node, {_, fns} ->
          {node, {true, fns}}

        {:@, _, [{:impl, _, _}]} = node, {_, fns} ->
          # @impl false or @impl SomeBehaviour — reset
          {node, {false, fns}}

        {:def, _, [{name, _, args} | _]} = node, {true, fns} when is_atom(name) ->
          arity = length(args || [])
          {node, {false, MapSet.put(fns, {name, arity})}}

        {:def, _, _} = node, {_, fns} ->
          {node, {false, fns}}

        node, acc ->
          {node, acc}
      end)

    impl_fns
  end

  defp noop_body?(nil), do: true

  defp noop_body?(body) do
    # AST.extract_functions returns body as [do: actual_body]
    actual = unwrap_do(body)
    normalized = normalize_body(actual)
    normalized in @noop_bodies or empty_collection?(normalized) or raise_not_implemented?(actual)
  end

  defp unwrap_do([do: body]), do: body
  defp unwrap_do(body), do: body

  defp normalize_body({:__block__, _, [single]}), do: {:__block__, normalize_body(single)}
  defp normalize_body(atom) when is_atom(atom), do: atom
  defp normalize_body([]), do: []
  defp normalize_body(_), do: :_other

  defp empty_collection?([]), do: true
  defp empty_collection?(_), do: false

  # raise "not implemented" or raise ArgumentError, "not implemented"
  defp raise_not_implemented?(body) do
    AST.contains?(body, fn
      {:raise, _, [msg]} when is_binary(msg) ->
        String.contains?(String.downcase(msg), "not implemented")

      {:raise, _, [_, msg]} when is_binary(msg) ->
        String.contains?(String.downcase(msg), "not implemented")

      _ ->
        false
    end)
  end

  # --- Phase 3: Diagnostics ---

  defp build_diagnostic(impl, behaviour, stubs, _behaviour_defs) do
    stub_names = Enum.map_join(stubs, ", ", fn s -> "#{s.name}/#{s.arity}" end)
    first_line =
      stubs
      |> Enum.map(& &1.line)
      |> Enum.min()

    Diagnostic.warning("4.21",
      title: "Behaviour implementation has no-op stubs",
      message:
        "#{impl.module} implements @behaviour #{behaviour} but stubs " <>
          "#{length(stubs)} callback(s) with no-ops: #{stub_names}",
      why:
        "When a behaviour implementation stubs callbacks with `:ok`, `nil`, or " <>
          "`raise \"not implemented\"`, it signals that the implementation doesn't need " <>
          "those parts of the interface. This is a classic Interface Segregation Principle " <>
          "violation — the behaviour is forcing implementations to carry dead weight. " <>
          "Each stub is a lie: callers think the operation is supported, but it silently " <>
          "does nothing.",
      alternatives: [
        Fix.new(
          summary: "Split the behaviour into focused sub-behaviours",
          detail:
            "Extract the stubbed callbacks into a separate behaviour. #{impl.module} " <>
              "only implements the behaviour it actually uses. Other implementations that " <>
              "need both can implement both behaviours.",
          applies_when: "Different implementations stub different subsets of callbacks."
        ),
        Fix.new(
          summary: "Mark the stubbed callbacks as @optional_callbacks",
          detail:
            "In the behaviour definition, add `@optional_callbacks #{stub_names}`. " <>
              "Implementations that don't need them can simply omit the functions. " <>
              "The compiler won't complain, and the intent is documented.",
          applies_when: "The callbacks are genuinely optional for some implementations."
        ),
        Fix.new(
          summary: "Implement the callbacks properly or remove the behaviour",
          detail:
            "If the stubs are temporary placeholders, implement them. If #{impl.module} " <>
              "shouldn't implement this behaviour at all, remove the `@behaviour` declaration.",
          applies_when: "The stubs are accidental, not architectural."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.21"],
      context: %{
        module: impl.module,
        behaviour: behaviour,
        stubs: Enum.map(stubs, fn s -> "#{s.name}/#{s.arity}" end)
      },
      file: impl.file,
      line: first_line
    )
  end
end
