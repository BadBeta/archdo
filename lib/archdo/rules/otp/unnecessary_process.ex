defmodule Archdo.Rules.OTP.UnnecessaryProcess do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.2"

  @impl true
  def description, do: "GenServer used for code organization, not state/concurrency/isolation"

  # Not used as a direct match — the heuristic is in trivial_init?/1

  @impl true
  def analyze(file, ast, _opts) do
    if AST.genserver_module?(ast) and not liveview_module?(ast) and
         not supervisor_module?(ast) and not framework_process?(ast) do
      check_for_unnecessary_genserver(file, ast)
    else
      []
    end
  end

  defp check_for_unnecessary_genserver(file, ast) do
    callbacks = AST.extract_callbacks(ast)

    trivial_init? = trivial_init?(callbacks[:init] || [])
    no_state_mutation? = no_state_mutation?(callbacks)
    no_side_effects? = no_side_effects_in_callbacks?(callbacks)

    if trivial_init? and no_state_mutation? and no_side_effects? do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.info("5.2",
          title: "Process without justification",
          message: "#{module_name} is a GenServer with trivial init state and no mutations or side effects in callbacks",
          why:
            "The official Elixir guide states a GenServer must never be used for code organization. Valid " <>
              "reasons to spawn a process are mutable state, concurrent execution, fault isolation, or resource " <>
              "ownership — none apply here. Each process costs heap, message-copy overhead, and serializes all " <>
              "access; the wrap turns a fast call into a queued message round-trip.",
          alternatives: [
            Fix.new(
              summary: "Convert the module to plain functions",
              detail:
                "Inline the public API functions (e.g. `MyApp.Foo.do_thing/1`) so callers invoke them directly. " <>
                  "Remove the GenServer behaviour, the start_link, and the supervision-tree entry. The result is " <>
                  "the same logic with no process indirection.",
              applies_when: "The module truly has no shared state or coordination."
            ),
            Fix.new(
              summary: "Move shared state into ETS or `:persistent_term`",
              detail:
                "If there is data the module needs to keep around (config, lookups), use ETS with " <>
                  "`read_concurrency: true` or `:persistent_term` for almost-static values. Both allow concurrent " <>
                  "reads with no GenServer bottleneck.",
              applies_when: "There is shared state but no need to serialize access."
            ),
            Fix.new(
              summary: "Keep the GenServer if a non-obvious reason justifies it",
              detail:
                "If the process exists for rate limiting, ordered execution, named registration, or being a " <>
                  "supervisor's child, document why in the moduledoc and add it to the freeze baseline.",
              applies_when: "There is a real OTP reason that the heuristic missed."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.2"],
          context: %{module: module_name},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp trivial_init?([]), do: true

  defp trivial_init?(init_clauses) do
    Enum.all?(init_clauses, fn {_meta, _args, body} ->
      AST.contains?(body, fn
        # 3+ element tuples use {:{}, _, [...]} in AST
        {:{}, _, [:ok, {:%{}, _, []}]} -> true
        {:{}, _, [:ok, []]} -> true
        {:{}, _, [:ok, nil]} -> true
        # 2-element tuples are represented as-is in AST
        {:ok, {:%{}, _, []}} -> true
        {:ok, []} -> true
        {:ok, nil} -> true
        _ -> false
      end)
    end)
  end

  defp no_state_mutation?(callbacks) do
    [:handle_call, :handle_cast, :handle_info]
    |> Enum.all?(fn cb_name ->
      (callbacks[cb_name] || [])
      |> Enum.all?(fn {_meta, _args, body} ->
        not mutates_state?(body)
      end)
    end)
  end

  defp mutates_state?(nil), do: false

  defp mutates_state?(body) do
    # Check if any callback returns a modified state
    AST.contains?(body, fn
      # Pattern: %{state | key: value} — struct update
      {:%{}, _, [{:|, _, _} | _]} -> true
      # Map.put, Map.merge, etc
      {{:., _, [{:__aliases__, _, [:Map]}, func]}, _, _}
      when func in [:put, :merge, :delete, :update, :put_new] ->
        true
      _ ->
        false
    end)
  end

  defp no_side_effects_in_callbacks?(callbacks) do
    [:handle_call, :handle_cast, :handle_info]
    |> Enum.all?(fn cb_name ->
      (callbacks[cb_name] || [])
      |> Enum.all?(fn {_meta, _args, body} ->
        not has_side_effects?(body)
      end)
    end)
  end

  defp has_side_effects?(nil), do: false

  defp has_side_effects?(body) do
    AST.contains?(body, fn
      {:send, _, _} -> true
      {{:., _, [{:__aliases__, _, [:GenServer]}, _]}, _, _} -> true
      {{:., _, [{:__aliases__, _, [:Process]}, _]}, _, _} -> true
      _ -> false
    end)
  end

  defp liveview_module?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, aliases} | rest]} ->
        mod = Module.concat(aliases)

        mod in [Phoenix.LiveView, Phoenix.LiveComponent, Phoenix.Channel] or
          match_phoenix_use_convention(rest)

      _ -> false
    end)
  end

  # use MyAppWeb, :live_view
  defp match_phoenix_use_convention([atom_arg]) when is_atom(atom_arg) do
    atom_arg in [:live_view, :live_component, :channel]
  end

  defp match_phoenix_use_convention([{:__block__, _, [atom_arg]}]) when is_atom(atom_arg) do
    atom_arg in [:live_view, :live_component, :channel]
  end

  defp match_phoenix_use_convention(_), do: false

  defp supervisor_module?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, aliases} | _]} ->
        case AST.safe_concat(aliases) do
          nil -> false
          mod -> mod in [Supervisor, DynamicSupervisor]
        end

      _ ->
        false
    end)
  end

  # Modules that MUST be processes by framework design
  defp framework_process?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, aliases} | _]} ->
        last = List.last(aliases)

        last in [
          # Membrane Framework
          :Bin, :Source, :Sink, :Filter, :Endpoint,
          # Broadway
          :Broadway,
          # GenStage
          :GenStage,
          # Phoenix
          :Channel, :Socket
        ]

      _ ->
        false
    end)
  end
end
