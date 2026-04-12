defmodule Archdo.Rules.OTP.SingletonBottleneck do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.29"

  @impl true
  def description, do: "Named GenServer handling entity-keyed requests — bottleneck risk"

  @impl true
  def analyze(file, ast, _opts) do
    if not AST.genserver_module?(ast) do
      []
    else
      check_singleton_with_id_dispatch(file, ast)
    end
  end

  defp check_singleton_with_id_dispatch(file, ast) do
    has_name_registration? = has_name_registration?(ast)
    has_map_state_with_id_lookup? = has_map_state_with_id_lookup?(ast)

    if has_name_registration? and has_map_state_with_id_lookup? do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.info("5.29",
          title: "Singleton GenServer bottleneck",
          message: "#{module_name} is a named GenServer storing per-entity state in a Map",
          why:
            "With N concurrent entities, every request queues behind every other request through one mailbox. " <>
              "If processing takes 1ms per request, the maximum throughput is ~1000 req/sec regardless of how " <>
              "many cores the box has. Amdahl's law applies: the singleton becomes the system's ceiling and " <>
              "the bottleneck is invisible until production load triggers it.",
          alternatives: [
            Fix.new(
              summary: "Use a process per entity via DynamicSupervisor + Registry",
              detail:
                "Spin up one GenServer per entity under a DynamicSupervisor and locate it via " <>
                  "`{:via, Registry, {MyApp.Registry, entity_id}}`. Independent entities run on independent " <>
                  "processes; the BEAM scheduler parallelizes them automatically.",
              applies_when: "Entities can be addressed by id and don't need cross-entity coordination."
            ),
            Fix.new(
              summary: "Move state into ETS and remove the GenServer entirely",
              detail:
                "If the singleton's only job is to look up entity state, replace it with a public ETS table " <>
                  "(`read_concurrency: true`). Reads happen on the calling process with no message round-trip.",
              applies_when: "The data fits ETS and writes are infrequent or independent."
            ),
            Fix.new(
              summary: "Use PartitionSupervisor to fan requests across N workers",
              detail:
                "If processing must remain on a GenServer (e.g. for ordering or transactional state), put a " <>
                  "PartitionSupervisor in front so the load is distributed across N independent partitions " <>
                  "instead of one. Cores get utilized and the bottleneck is divided by N.",
              applies_when: "You need GenServer semantics but can partition by id."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.29"],
          context: %{module: module_name},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp has_name_registration?(ast) do
    AST.contains?(ast, fn
      # name: __MODULE__ or name: MyServer
      {:name, {:__MODULE__, _, _}} -> true
      {:name, {:__aliases__, _, _}} -> true
      _ -> false
    end)
  end

  defp has_map_state_with_id_lookup?(ast) do
    callbacks = AST.extract_callbacks(ast)

    [:handle_call, :handle_cast]
    |> Enum.any?(fn cb ->
      (callbacks[cb] || [])
      |> Enum.any?(fn {_, _, body} ->
        body != nil and has_map_get_or_fetch?(body)
      end)
    end)
  end

  defp has_map_get_or_fetch?(body) do
    AST.contains?(body, fn
      {{:., _, [{:__aliases__, _, [:Map]}, func]}, _, _}
      when func in [:get, :fetch, :fetch!, :get_and_update] ->
        true

      # state[key] or state.key access patterns
      {{:., _, [Access, :get]}, _, _} ->
        true

      _ ->
        false
    end)
  end

end
