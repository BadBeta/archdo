defmodule Archdo.Rules.OTP.CallSelfDeadlock do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.38"

  @impl true
  def description, do: "GenServer.call to self from callback — instant deadlock"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      case AST.genserver_module?(ast) do
        false -> []
        true -> find_self_calls(file, ast)
      end
    end
  end

  defp find_self_calls(file, ast) do
    callbacks = AST.extract_callbacks(ast)

    [:handle_call, :handle_cast, :handle_info, :handle_continue]
    |> Enum.flat_map(fn cb_name ->
      callbacks
      |> Map.get(cb_name, [])
      |> Enum.flat_map(fn {_meta, _args, body} ->
        find_genserver_call_self(body)
      end)
    end)
    |> Enum.map(fn {line} ->
      Diagnostic.warning("5.38",
        title: "GenServer.call to self — deadlock",
        message: "GenServer.call targets __MODULE__ or self() from within a callback",
        why:
          "A GenServer processes one message at a time. If handle_call/3 calls " <>
            "GenServer.call(__MODULE__, ...) or GenServer.call(self(), ...), the call blocks " <>
            "waiting for a reply — but the GenServer can't process the new call because it's " <>
            "still in the current callback. Result: instant deadlock, the process hangs forever.",
        alternatives: [
          Fix.new(
            summary: "Extract the logic into a private function and call it directly",
            detail:
              "If you need to reuse logic from another callback, extract it into a `defp` " <>
                "and call it from both callbacks. No message passing needed.",
            applies_when: "The logic doesn't need to go through the GenServer mailbox."
          ),
          Fix.new(
            summary: "Use GenServer.cast instead if you don't need the reply",
            detail:
              "Cast is asynchronous — it won't block. But the reply arrives later via " <>
                "a separate handle_cast clause.",
            applies_when: "You don't need the result synchronously."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.38"],
        context: %{},
        file: file,
        line: line
      )
    end)
  end

  defp find_genserver_call_self(nil), do: []

  defp find_genserver_call_self(body) do
    Enum.map(AST.find_all(body, fn
      {{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, _, [target | _]} ->
        self_target?(target)

      _ ->
        false
    end), fn {_, meta, _} -> {AST.line(meta)} end)
  end

  defp self_target?({:__MODULE__, _, _}), do: true
  defp self_target?({{:., _, [{:__aliases__, _, [:Kernel]}, :self]}, _, _}), do: true
  defp self_target?({:self, _, []}), do: true
  defp self_target?(_), do: false
end
