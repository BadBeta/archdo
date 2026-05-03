defmodule Archdo.Compiled.Tracer do
  @moduledoc false

  # Compilation tracer that captures cross-reference data during compilation.
  #
  # Usage: add to compiler options before compiling a project:
  #
  #     Code.put_compiler_option(:tracers, [Archdo.Compiled.Tracer])
  #
  # The tracer sends events to a collector process (Archdo.Compiled.Collector)
  # which aggregates them. This is the modern replacement for Mix.Tasks.Xref.calls/0.
  #
  # The tracer MUST be fast — it runs synchronously during compilation.
  # We send a message to the collector and return immediately.

  Module.register_attribute(__MODULE__, :archdo_anchor, persist: true)

  @archdo_anchor "Compiler tracer registered at runtime via Code.put_compiler_option(:tracers, [...]) in --compiled mode; no static call edge"

  @doc """
  Trace callback invoked by the Elixir compiler for each event.
  Dispatches relevant events to the collector process.
  """
  def trace({:remote_function, meta, module, name, arity}, env) do
    send_event(:remote_call, %{
      caller_module: env.module,
      callee_module: module,
      callee_function: name,
      callee_arity: arity,
      file: env.file,
      line: meta[:line] || env.line
    })
  end

  def trace({:imported_function, meta, module, name, arity}, env) do
    send_event(:remote_call, %{
      caller_module: env.module,
      callee_module: module,
      callee_function: name,
      callee_arity: arity,
      file: env.file,
      line: meta[:line] || env.line
    })
  end

  def trace({:struct_expansion, meta, module, _keys}, env) do
    send_event(:struct_reference, %{
      caller_module: env.module,
      struct_module: module,
      file: env.file,
      line: meta[:line] || env.line
    })
  end

  def trace({:on_module, _bytecode, _ignore}, env) do
    send_event(:module_defined, %{
      module: env.module,
      file: env.file
    })
  end

  def trace(_event, _env), do: :ok

  defp send_event(type, data) do
    case Process.whereis(Archdo.Compiled.Collector) do
      nil -> :ok
      pid -> send(pid, {type, data})
    end

    :ok
  end
end
