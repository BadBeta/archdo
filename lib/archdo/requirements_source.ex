defmodule Archdo.RequirementsSource do
  @moduledoc """
  Loads project-level requirements from a CSV / Markdown / TOML
  source file, used by CE-32 (MissingTraceability) and CE-33
  (DeadRequirement) to verify code-to-requirement linkage. Public
  API for the compliance pack.
  """

  # Reading the requirements JSON file IS the responsibility.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  # `{:error, _}` returned to caller (rule decides whether file is required).
  Module.register_attribute(__MODULE__, :archdo_silent_error, persist: true)
  @archdo_silent_error true

  # §§ elixir-planning: §6 — Foundation for CE-33 (dead requirement).
  # Reads a JSON file enumerating the project's requirement IDs.
  # Two accepted shapes:
  #
  #   1. Flat list of strings:    ["REQ-1234", "REQ-1235", "REQ-1236"]
  #   2. List of objects:         [{"id": "REQ-1", "status": "active"}, ...]
  #
  # Status-aware exemption: requirements with statuses in
  # `@exempt_statuses` ARE skipped (cancelled, deferred, out_of_scope).

  @exempt_statuses ~w(cancelled deferred out_of_scope not_in_scope)

  @type entry :: %{id: String.t(), status: String.t() | nil}

  @doc """
  Load and parse a requirements source file. Returns `[entry()]` or
  `{:error, reason}` if the file is missing/malformed.
  """
  @spec load(String.t()) :: {:ok, [entry()]} | {:error, term()}
  def load(path) when is_binary(path) do
    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content) do
      {:ok, normalize(parsed)}
    else
      false -> {:error, :enoent}
      {:error, _} = error -> error
    end
  end

  defp normalize(list) when is_list(list) do
    Enum.flat_map(list, fn
      id when is_binary(id) -> [%{id: id, status: nil}]
      %{"id" => id} = obj when is_binary(id) -> [%{id: id, status: obj["status"]}]
      _ -> []
    end)
  end

  defp normalize(_), do: []

  @doc """
  Filter out entries whose status excludes them from CE-33 firing.
  """
  @spec actionable([entry()]) :: [entry()]
  def actionable(entries) do
    Enum.reject(entries, fn %{status: status} -> status in @exempt_statuses end)
  end

  @doc """
  Set of requirement IDs that should be considered when checking for
  dead requirements (status-filtered).
  """
  @spec actionable_ids([entry()]) :: MapSet.t(String.t())
  def actionable_ids(entries) do
    entries |> actionable() |> Enum.map(& &1.id) |> MapSet.new()
  end
end
