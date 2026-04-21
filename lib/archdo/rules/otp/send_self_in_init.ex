defmodule Archdo.Rules.OTP.SendSelfInInit do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.12"

  @impl true
  def description, do: "Use handle_continue instead of send(self()) in init"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.genserver_module?(ast) do
      false ->
        []
      true ->
      callbacks = AST.extract_callbacks(ast)

      Enum.flat_map(callbacks[:init] || [], fn {_meta, _args, body} ->
        find_send_self(file, body)
      end)
    end
  end

  defp find_send_self(_file, nil), do: []

  defp find_send_self(file, body) do
    Enum.map(AST.find_all(body, fn
      {:send, _meta, [{:self, _, _} | _]} -> true
      {:send, _meta, [{{:., _, [{:__aliases__, _, [:Kernel]}, :self]}, _, _} | _]} -> true
      _ -> false
    end), fn {_, meta, _} ->
      Diagnostic.warning("5.12",
        title: "send(self()) in init/1",
        message: "init/1 sends a message to self instead of returning a continue tuple",
        why:
          "Between init/1 returning and the GenServer processing its mailbox, other processes can already " <>
            "send messages to the just-started pid (especially if it's named or registered). The self-sent " <>
            "message is no longer guaranteed to be processed first, which is exactly the race that " <>
            "`{:continue, ...}` was added in OTP 21 to eliminate.",
        alternatives: [
          Fix.new(
            summary: "Return `{:ok, state, {:continue, :post_init}}` and move the work to handle_continue/2",
            detail:
              "handle_continue/2 is guaranteed to run before any other message — even if other processes are " <>
                "already sending. Move the body of the self-message handler into handle_continue/2 and remove " <>
                "the send(self(), ...) call.",
            example: """
            ```elixir
            def init(args) do
              {:ok, %{ready: false}, {:continue, :post_init}}
            end

            def handle_continue(:post_init, state) do
              # work that used to live in handle_info(:post_init, ...)
              {:noreply, %{state | ready: true}}
            end
            ```
            """,
            applies_when: "Always — handle_continue exists specifically to replace this pattern."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#5.12"],
        context: %{},
        file: file,
        line: AST.line(meta)
      )
    end)
  end
end
