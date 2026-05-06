defmodule Archdo.Rules.OTP.ApplicationGetEnvInCallback do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.71"

  @impl true
  def description,
    do:
      "`Application.get_env` / `fetch_env` inside a GenServer `handle_call` / " <>
        "`handle_cast` / `handle_info` — runs on every message; consider " <>
        "`:persistent_term` or capture in init"

  @callback_funs [:handle_call, :handle_cast, :handle_info, :handle_continue]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    ast
    |> AST.find_all(&callback_def?/1)
    |> Enum.flat_map(&hits_in_callback/1)
    |> Enum.map(fn meta -> build_diagnostic(file, AST.line(meta)) end)
  end

  defp callback_def?({:def, _, [{name, _, _args}, _]})
       when name in @callback_funs,
       do: true

  defp callback_def?(_), do: false

  defp hits_in_callback({:def, _, [_head, [{_, body}]]}) do
    body
    |> AST.find_all(&app_env_call?/1)
    |> Enum.map(fn {_, meta, _} -> meta end)
  end

  defp hits_in_callback(_), do: []

  defp app_env_call?({{:., _, [{:__aliases__, _, [:Application]}, fun]}, _, _})
       when fun in [:get_env, :fetch_env, :fetch_env!],
       do: true

  defp app_env_call?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("5.71",
      title: "`Application.get_env` in GenServer callback — capture or use `:persistent_term`",
      message:
        "This `handle_call` / `handle_cast` / `handle_info` reads from " <>
          "`Application.get_env` / `fetch_env` on every message. The Application " <>
          "ETS table is fast but it's still a lookup-per-message; for a hot path " <>
          "(every cast / call / message), the value can be cached.",
      why:
        "Two cleaner shapes exist. (1) Capture the value in `init/1` if it does " <>
          "NOT change at runtime — store it in state, read from `state.backend` " <>
          "for free. (2) Put it in `:persistent_term` if the value DOES change " <>
          "(reload from config) but the read needs to be O(1) and lock-free " <>
          "across processes. The third path — leave the `Application.get_env` " <>
          "call where it is — is fine for cold or low-frequency callbacks but " <>
          "wastes work in hot loops, and it makes the callback's behaviour " <>
          "depend on global mutable state that isn't visible at the call site.",
      alternatives: [
        Fix.new(
          summary: "Capture in `init/1`, read from state",
          detail:
            "def init(_) do\n" <>
              "  backend = Application.fetch_env!(:my_app, :backend)\n" <>
              "  {:ok, %{backend: backend}}\nend\n\n" <>
              "def handle_call({:resolve, key}, _, %{backend: backend} = state) do\n" <>
              "  {:reply, backend.lookup(key), state}\nend",
          applies_when: "When the config value is fixed for the GenServer's lifetime."
        ),
        Fix.new(
          summary: "Or `:persistent_term` for hot-path reads that may change",
          detail:
            "# Once at boot:\n" <>
              ":persistent_term.put(MyApp.Resolver.Backend,\n" <>
              "  Application.fetch_env!(:my_app, :backend))\n\n" <>
              "# In the callback (O(1), lock-free across schedulers):\n" <>
              "def handle_call({:resolve, key}, _, state) do\n" <>
              "  backend = :persistent_term.get(MyApp.Resolver.Backend)\n" <>
              "  {:reply, backend.lookup(key), state}\nend",
          applies_when:
            "When the value can be replaced (via a deliberate `put`) but reads must be hot."
        )
      ],
      references: [
        "elixir-implementing/SKILL.md#9.2.2",
        "elixir-implementing/SKILL.md#10.5.1"
      ],
      context: %{},
      file: file,
      line: line
    )
  end
end
