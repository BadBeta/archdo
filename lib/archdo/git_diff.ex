defmodule Archdo.GitDiff do
  @moduledoc """
  Project-wide thin wrapper over `git diff --name-only`. Used by the MCP
  `archdo_diff` tool and the CLI `--since=<ref>` flag — same shell-out,
  one home.
  """

  # Shell-out to `git` IS the responsibility — the module IS the seam.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  @doc """
  Return the list of `.ex` files changed (added/copied/modified/renamed)
  between `ref` and the working tree, scoped to `base_paths`. Files that
  no longer exist on disk are filtered out.

  Returns `{:ok, files}` on success, `{:error, message}` if `git` errors.
  """
  @spec changed_files(String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def changed_files(ref, base_paths) when is_binary(ref) and is_list(base_paths) do
    case System.cmd(
           "git",
           ["diff", "--name-only", "--diff-filter=ACMR", ref, "--"] ++ base_paths,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&(String.ends_with?(&1, ".ex") and File.exists?(&1)))

        {:ok, files}

      {error, _code} ->
        {:error, "git diff failed: #{String.trim(error)}"}
    end
  end
end
