defmodule Archdo.Rules.OTP.HardcodedCallTimeout do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.41"

  @impl true
  def description, do: "GenServer.call with hardcoded integer timeout — use a named constant"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_hardcoded_timeouts(file, ast)
    end
  end

  defp find_hardcoded_timeouts(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        # GenServer.call(server, msg, 5000)
        {{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, _, [_, _, timeout]} ->
          hardcoded_integer?(timeout)

        _ ->
          false
      end),
      fn {_, meta, [_, _, timeout]} ->
        value = extract_integer(timeout)

        Diagnostic.info("5.41",
          title: "Hardcoded GenServer.call timeout",
          message: "GenServer.call uses hardcoded timeout #{value}ms — use a module attribute",
          why:
            "Hardcoded timeout values scattered across call sites make it impossible to tune " <>
              "timeouts without finding every occurrence. Different environments (dev vs prod) " <>
              "and different load conditions may need different values. A module attribute or " <>
              "application config makes the value discoverable and adjustable.",
          alternatives: [
            Fix.new(
              summary: "Extract to a module attribute",
              detail:
                "```elixir\n" <>
                  "@call_timeout 15_000\n" <>
                  "GenServer.call(server, msg, @call_timeout)\n" <>
                  "```",
              applies_when: "The timeout is fixed per module."
            ),
            Fix.new(
              summary: "Accept timeout as a function parameter with default",
              detail: "`def fetch(key, timeout \\\\ 15_000), do: GenServer.call(..., timeout)`",
              applies_when: "Callers may need different timeouts."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.41"],
          context: %{timeout: value},
          file: file,
          line: AST.line(meta)
        )
      end
    )
  end

  defp hardcoded_integer?({:__block__, _, [n]}) when is_integer(n), do: true
  defp hardcoded_integer?(n) when is_integer(n), do: true
  defp hardcoded_integer?(_), do: false

  defp extract_integer({:__block__, _, [n]}), do: n
  defp extract_integer(n) when is_integer(n), do: n
  defp extract_integer(_), do: 0
end
