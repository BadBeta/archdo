defmodule Archdo.Compiled.Collector do
  @moduledoc false

  # Collects trace events from the compilation tracer.
  # Started before compilation, stopped after to harvest results.
  #
  # The collector is a simple GenServer that accumulates events
  # in memory. Since compilation tracers must be fast (synchronous
  # during compilation), the tracer sends messages and the collector
  # processes them asynchronously.

  use GenServer

  # §§ elixir-implementing: §9.6 #6 — exempt from CE-29 (opaque-state
  # rule). The collector is a transient compilation buffer with no
  # external observers and no PII; format_status/1 would add no value.
  @archdo_opaque_state "transient compilation buffer; no external observers"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stop do
    GenServer.stop(__MODULE__)
  end

  @doc """
  Get all collected data. Call after compilation completes.
  """
  def get_data do
    GenServer.call(__MODULE__, :get_data)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{calls: [], struct_refs: [], modules: []}}
  end

  @impl true
  def handle_info({:remote_call, data}, state) do
    {:noreply, %{state | calls: [data | state.calls]}}
  end

  def handle_info({:struct_reference, data}, state) do
    {:noreply, %{state | struct_refs: [data | state.struct_refs]}}
  end

  def handle_info({:module_defined, data}, state) do
    {:noreply, %{state | modules: [data | state.modules]}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_data, _from, state) do
    {:reply, state, state}
  end
end
