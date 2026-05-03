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
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_.]*(?:\.[a-z_][a-z0-9_!?]*)?)\((.*)\)$/s, call) do
      [_, func_name, existing_args] ->
        new_args =
          case String.trim(existing_args) do
            "" -> input
            args -> "#{input}, #{args}"
          end

        "#{func_name}(#{new_args})"

      _ ->
        case Regex.run(
               ~r/^([A-Za-z_][A-Za-z0-9_.]*(?:\.[a-z_][a-z0-9_!?]*)?)$/,
               String.trim(call)
             ) do
          [_, func_name] -> "#{func_name}(#{input})"
          _ -> nil
        end
    end
  end
end
