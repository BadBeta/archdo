defmodule Archdo.Rules.OTP.GenTcpRecvNoTimeout do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.73"

  @impl true
  def description,
    do:
      "`:gen_tcp.recv/2` or `:gen_tcp.connect/3` without explicit timeout — " <>
        "default `:infinity` blocks indefinitely on a quiet peer"

  # Each tuple: {module, function, arity-without-timeout}.
  @timeout_calls [
    {:gen_tcp, :recv, 2},
    {:gen_tcp, :connect, 3},
    {:ssl, :recv, 2},
    {:ssl, :connect, 3}
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    ast
    |> AST.find_all(&untimed_socket_call?/1)
    |> Enum.map(fn node -> build_diagnostic(file, line_of(node), name_of(node)) end)
  end

  defp untimed_socket_call?({{:., _, [mod, fun]}, _, args})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    {mod, fun, length(args)} in @timeout_calls
  end

  defp untimed_socket_call?(_), do: false

  defp line_of({_, meta, _}), do: AST.line(meta)

  defp name_of({{:., _, [mod, fun]}, _, args}),
    do: "#{inspect(mod)}.#{fun}/#{length(args)}"

  defp build_diagnostic(file, line, call) do
    Diagnostic.info("5.73",
      title: "`#{call}` without explicit timeout — default is `:infinity`",
      message:
        "This `#{call}` call omits the timeout argument. The default for " <>
          "`:gen_tcp` / `:ssl` is `:infinity` — if the peer never sends (or never " <>
          "completes the connection), the calling process blocks forever. In " <>
          "production this leaks processes, masks network problems, and prevents " <>
          "graceful shutdown.",
      why:
        "Network code's primary failure mode is silence — the connection completes " <>
          "but the bytes never arrive (load balancer black-holes, half-closed " <>
          "connection, slow server). An explicit timeout converts this from a " <>
          "process leak into a `{:error, :timeout}` return that the caller can " <>
          "handle: retry with backoff, fall back to a degraded path, surface the " <>
          "incident. Size the timeout to your SLO — connect timeouts are usually " <>
          "1–5 seconds; recv timeouts are protocol-specific (sub-second for " <>
          "ack-style protocols, tens of seconds for slow APIs).",
      alternatives: [
        Fix.new(
          summary: "Add an explicit timeout matching the protocol SLO",
          detail:
            ":gen_tcp.recv(sock, 0, 30_000)\n" <>
              ":gen_tcp.connect(host, port, opts, 5_000)\n\n" <>
              "case :gen_tcp.recv(sock, 0, 30_000) do\n" <>
              "  {:ok, data} -> handle(data)\n" <>
              "  {:error, :timeout} -> retry_or_close(sock)\n" <>
              "  {:error, :closed} -> :ok\n" <>
              "end",
          applies_when: "Always — there is no use case for an `:infinity` socket call in production."
        )
      ],
      references: [
        "elixir-implementing/networking-patterns.md",
        "elixir-implementing/SKILL.md#9.2"
      ],
      context: %{call: call},
      file: file,
      line: line
    )
  end
end
