defmodule Archdo.Rules.OTP.GenTcpActiveTrue do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "5.72"

  @impl true
  def description,
    do:
      "`:gen_tcp.*` / `:gen_udp.open` opened with `active: true` — unbounded " <>
        "incoming data overflows the mailbox; use `active: :once` or `active: N`"

  @socket_calls [
    {:gen_tcp, :listen},
    {:gen_tcp, :connect},
    {:gen_tcp, :accept},
    {:gen_udp, :open},
    {:ssl, :listen},
    {:ssl, :connect}
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
    |> AST.find_all(&socket_call_with_active_true?/1)
    |> Enum.map(fn {_, meta, _} -> build_diagnostic(file, AST.line(meta)) end)
  end

  defp socket_call_with_active_true?({{:., _, [mod, fun]}, _, args})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    {mod, fun} in @socket_calls and any_arg_has_active_true?(args)
  end

  defp socket_call_with_active_true?(_), do: false

  defp any_arg_has_active_true?(args) do
    Enum.any?(args, fn
      list when is_list(list) -> active_true_in_opts?(list)
      _ -> false
    end)
  end

  defp active_true_in_opts?(opts) do
    case Unwrap.kw_get(opts, :active) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp build_diagnostic(file, line) do
    Diagnostic.warning("5.72",
      title: "`active: true` on socket — mailbox overflow risk",
      message:
        "This socket is opened with `active: true`. The BEAM will deliver every " <>
          "incoming packet to the owning process's mailbox as fast as the network " <>
          "delivers them. A fast peer (or a malicious one) fills the mailbox " <>
          "unboundedly, which exhausts memory and crashes the node. Use " <>
          "`active: :once` for one-frame-at-a-time backpressure, or `active: N` " <>
          "for batched delivery with periodic re-arming.",
      why:
        "`active: true` is the convenience setting — useful in IEx exploration, " <>
          "demo code, and tests where the peer is well-behaved. In production, " <>
          "the only safe modes are `:once` (the default for connection servers), " <>
          "an integer N (for batched protocols), or `false` (passive — call " <>
          "`recv/2` explicitly). The BEAM's `{:tcp_passive, sock}` message is the " <>
          "natural backpressure signal for `active: N`; pair the two and you get " <>
          "automatic flow control without writing your own loop.",
      alternatives: [
        Fix.new(
          summary: "Use `active: :once` (one frame at a time)",
          detail:
            ":gen_tcp.listen(port, [:binary, packet: 4, active: :once, reuseaddr: true])\n\n" <>
              "# In the handler, re-arm after each frame:\n" <>
              "receive do\n" <>
              "  {:tcp, ^sock, data} ->\n" <>
              "    handle(data)\n" <>
              "    :inet.setopts(sock, active: :once)\n" <>
              "    handle_loop(sock)\n" <>
              "end",
          applies_when: "Default — single-frame protocols, request/response."
        ),
        Fix.new(
          summary: "Or `active: N` for batched protocols",
          detail:
            ":inet.setopts(sock, active: 100)\n" <>
              "# After 100 frames, BEAM sends {:tcp_passive, sock} — re-arm there.",
          applies_when: "High-throughput streaming where per-frame setopts has overhead."
        )
      ],
      references: [
        "elixir-implementing/networking-patterns.md",
        "elixir-implementing/SKILL.md#9.2"
      ],
      context: %{},
      file: file,
      line: line
    )
  end
end
