defmodule Archdo.PipeRewriter do
  @moduledoc """
  Project-wide source-text helper for rewriting single-line pipelines into
  direct function calls. Used by both the MCP `archdo_fix` tool and the
  CLI `--fix` flag — same logic, one home.

  Operates on raw source strings, not AST. Conservative: only rewrites
  when the input expression is a simple variable, function call, or
  module-qualified call; declines anything that risks semantic breakage.
  """

  @doc """
  Predicate — is the pipeline input safe to rewrite as a leading argument?

  Returns true only for simple expressions: a bare variable, a local
  function call, a `Module.fun(...)` call, or a list literal. Returns
  false for everything else (assignments, multi-statement expressions,
  embedded keyword values, etc.).
  """
  @spec safe_to_rewrite?(String.t(), String.t()) :: boolean()
  def safe_to_rewrite?(input, _line) when is_binary(input) do
    String.match?(input, ~r/^[a-z_]\w*$/) or
      String.match?(input, ~r/^[a-z_]\w*\(.*\)$/) or
      String.match?(input, ~r/^[A-Z]\w*(?:\.[A-Z]\w*)*\.[a-z_]\w*\(.*\)$/) or
      String.match?(input, ~r/^\[.*\]$/)
  end

  @doc """
  Rewrite a single line containing one `|>` into a direct call. Returns
  the rewritten source string, or `nil` if the line doesn't match the
  pipe shape or the input expression isn't safe to rewrite.
  """
  @spec rewrite_line(String.t()) :: String.t() | nil
  def rewrite_line(line) when is_binary(line) do
    case Regex.run(~r/^(.+?)\s*\|>\s*(.+)$/, line) do
      [_, input, call] ->
        input = String.trim(input)

        case safe_to_rewrite?(input, line) do
          true -> rewrite(input, call)
          false -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Rewrite a pipe call. `input` is the left-hand side of the `|>`,
  `call` is the right-hand side. Returns the rewritten source as a
  string, or `nil` if the call shape isn't recognized.

  Examples:
      iex> Archdo.PipeRewriter.rewrite("foo", "Mod.bar(x)")
      "Mod.bar(foo, x)"
      iex> Archdo.PipeRewriter.rewrite("foo", "Mod.bar()")
      "Mod.bar(foo)"
      iex> Archdo.PipeRewriter.rewrite("foo", "bar")
      "bar(foo)"
  """
  @spec rewrite(String.t(), String.t()) :: String.t() | nil
  def rewrite(input, call) when is_binary(input) and is_binary(call) do
    rewrite_classified(classify_call(call), input)
  end

  @func_call_re ~r/^([A-Za-z_][A-Za-z0-9_.]*(?:\.[a-z_][a-z0-9_!?]*)?)\((.*)\)$/s
  @bare_name_re ~r/^([A-Za-z_][A-Za-z0-9_.]*(?:\.[a-z_][a-z0-9_!?]*)?)$/

  defp classify_call(call) do
    case Regex.run(@func_call_re, call) do
      [_, name, args] -> {:func_call, name, String.trim(args)}
      _ -> classify_bare_name(call)
    end
  end

  defp classify_bare_name(call) do
    case Regex.run(@bare_name_re, String.trim(call)) do
      [_, name] -> {:bare_name, name}
      _ -> :unrecognized
    end
  end

  defp rewrite_classified({:func_call, name, ""}, input), do: "#{name}(#{input})"
  defp rewrite_classified({:func_call, name, args}, input), do: "#{name}(#{input}, #{args})"
  defp rewrite_classified({:bare_name, name}, input), do: "#{name}(#{input})"
  defp rewrite_classified(:unrecognized, _input), do: nil
end
