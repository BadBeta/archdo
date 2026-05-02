defmodule Archdo.Rules.Boundary.DirectProcessCall do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — operational layer carve-out via Archdo.Phoenix.
  # Mix tasks and release scripts orchestrate across contexts intentionally.

  alias Archdo.{AST, Diagnostic, Fix, Phoenix}

  @impl true
  def id, do: "1.30"

  @impl true
  def description,
    do: "Direct GenServer.call to another context's process — use the context's public API"

  @impl true
  def analyze(file, ast, opts) do
    classification =
      case Keyword.get(opts, :phoenix) do
        %{layer: _} = c -> c
        _ -> Phoenix.classify_file(file, ast)
      end

    case AST.test_file?(file) or Phoenix.operational?(classification) do
      true -> []
      false -> find_direct_process_calls(file, ast)
    end
  end

  defp find_direct_process_calls(file, ast) do
    own_context = Phoenix.context_for_file(file)

    case own_context do
      nil -> []
      ctx -> find_foreign_genserver_calls(file, ast, ctx)
    end
  end

  defp find_foreign_genserver_calls(file, ast, own_context) do
    Enum.map(
      AST.find_all(ast, fn
        # GenServer.call(OtherContext.SomeServer, msg)
        {{:., _, [{:__aliases__, _, [:GenServer]}, func]}, _, [{:__aliases__, _, aliases} | _]}
        when func in [:call, :cast] ->
          foreign_context_process?(aliases, own_context)

        # GenServer.call(OtherContext.SomeServer, msg, timeout)
        {{:., _, [{:__aliases__, _, [:GenServer]}, func]}, _, [{:__aliases__, _, aliases}, _, _]}
        when func in [:call, :cast] ->
          foreign_context_process?(aliases, own_context)

        _ ->
          false
      end),
      fn {_, meta, _} ->
        build_diagnostic(file, AST.line(meta), own_context)
      end
    )
  end

  defp foreign_context_process?(aliases, own_context)
       when is_list(aliases) and length(aliases) >= 2 do
    context_atom = Enum.at(aliases, 1)

    case is_atom(context_atom) do
      true ->
        foreign = Atom.to_string(context_atom)
        foreign != own_context and foreign != "GenServer"

      false ->
        false
    end
  end

  defp foreign_context_process?(_, _), do: false

  defp build_diagnostic(file, line, own_context) do
    Diagnostic.info("1.30",
      title: "Direct process call across context boundary",
      message: "#{own_context} calls GenServer.call/cast to another context's process directly",
      why:
        "Calling another context's GenServer by name bypasses its public API. " <>
          "The caller becomes coupled to the process name, message format, and " <>
          "internal state shape. If the target process is refactored (renamed, " <>
          "split, or removed), every direct caller breaks.",
      alternatives: [
        Fix.new(
          summary: "Call the owning context's public API function",
          detail:
            "Instead of `GenServer.call(OtherCtx.Server, {:get, id})`, call " <>
              "`OtherCtx.get(id)` which wraps the process communication.",
          applies_when: "The target process belongs to a different bounded context."
        )
      ],
      file: file,
      line: line
    )
  end
end
