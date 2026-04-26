defmodule Archdo.Rules.NIF.PortVsNif do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "11.4"

  @impl true
  def description, do: "Choose Port when safety matters more than NIF latency"

  @impl true
  def analyze(file, ast, _opts) do
    case {AST.nif_module?(ast), does_io?(ast)} do
      {true, true} ->
        module_name = AST.extract_module_name(ast)

        [
          Diagnostic.info("11.4",
            title: "I/O-performing NIF — consider a Port",
            message:
              "NIF module #{module_name} has function names suggesting I/O (read/write/fetch/connect/...)",
            why:
              "NIFs share an OS process with the BEAM, so I/O bugs (segfault on a bad fd, library OOM) take " <>
                "the entire VM down. Ports run in a separate OS process: I/O happens there, errors are " <>
                "communicated back as messages, and a crashing port doesn't kill the BEAM. The latency cost " <>
                "of crossing the process boundary is usually trivial compared to the I/O time itself.",
            alternatives: [
              Fix.new(
                summary: "Replace the NIF with a Port",
                detail:
                  "Build the I/O-doing functionality as a small standalone executable that talks line-protocol " <>
                    "or `:erlang.term_to_binary/1` over stdin/stdout. Use `Port.open/2` from Elixir and treat " <>
                    "responses as messages. The OS process can crash without affecting the BEAM.",
                applies_when: "The operation is I/O-bound and Port latency is acceptable."
              ),
              Fix.new(
                summary: "Keep the NIF if latency is critical and use dirty I/O schedulers",
                detail:
                  "If you can't afford the Port overhead, at least mark the NIF as `dirty: :io` so it doesn't " <>
                    "block normal schedulers, and audit the native code carefully for crash-safety. The risk " <>
                    "remains real but is mitigated.",
                applies_when: "Latency overrules safety and you've audited the native code."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#11.4"],
            context: %{module: module_name},
            file: file,
            line: 1
          )
        ]

      _ ->
        []
    end
  end

  defp does_io?(ast) do
    # Heuristic: check for function names suggesting I/O
    fns = AST.extract_functions(ast, :public)

    Enum.any?(fns, fn
      {name, _arity, _, _, _} when is_atom(name) ->
        name_str = Atom.to_string(name)

        String.contains?(name_str, "read") or
          String.contains?(name_str, "write") or
          String.contains?(name_str, "fetch") or
          String.contains?(name_str, "download") or
          String.contains?(name_str, "upload") or
          String.contains?(name_str, "send") or
          String.contains?(name_str, "recv") or
          String.contains?(name_str, "connect") or
          String.contains?(name_str, "request")

      _ ->
        false
    end)
  end
end
