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
  # Module.register_attribute/3 with persist: true lets the marker
  # exist in BEAM metadata for static analysis without triggering
  # the "set but never used" compiler warning.
  Module.register_attribute(__MODULE__, :archdo_opaque_state, persist: true)
  @archdo_opaque_state "transient compilation buffer; no external observers"

  # Started by `Archdo.Compiled` in --compiled mode and located via
  # `Process.whereis/1` from `Archdo.Compiled.Tracer`. Neither path is
  # a static call edge, so the AST graph misses the wiring. The marker
  # makes this module reachable for the closure walk.
  Module.register_attribute(__MODULE__, :archdo_anchor, persist: true)

  @archdo_anchor "Named GenServer started in --compiled mode and located by Process.whereis/1 from the compiler tracer"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stop do
    GenServer.stop(__MODULE__)
  end

  # Compilation traces from a large project can be hundreds of
  # thousands of entries. The default 5s GenServer.call timeout is
  # too tight for `:get_data` — make it explicit and generous.
  @get_data_timeout :timer.seconds(30)

  @doc """
  Get all collected data. Call after compilation completes.
  """
  def get_data do
    GenServer.call(__MODULE__, :get_data, @get_data_timeout)
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

  # No catch-all on handle_info — let GenServer's default
  # implementation log any unexpected message at :error level
  # (Elixir 1.15+). The tracer sends only the three tagged
  # messages above; anything else (stray :DOWN from a monitor we
  # don't have, etc.) is genuinely unexpected and worth a log
  # entry, not a silent drop.

  @impl true
  def handle_call(:get_data, _from, state) do
    {:reply, state, state}
  end
end
