defmodule Archdo.Rule do
  @moduledoc false

  # §§ elixir-planning: §6 — Pack abstraction (M13). Rules optionally declare
  # `pack/0` to opt into one of the optional CE packs; runner filters by
  # enabled packs before invoking rules. Default `:core` keeps every existing
  # rule active without code change.

  @type pack :: :core | :ce_compliance | :ce_privacy | :ce_composability

  @known_packs [:core, :ce_compliance, :ce_privacy, :ce_composability]

  @doc """
  Analyze a single file's AST and return a list of diagnostics.

  Receives the file path, the quoted AST, and options.
  """
  @callback analyze(file :: String.t(), ast :: Macro.t(), opts :: keyword()) ::
              [Archdo.Diagnostic.t()]

  @doc """
  The rule identifier (e.g., "5.11").
  """
  @callback id() :: String.t()

  @doc """
  Short description of what the rule checks.
  """
  @callback description() :: String.t()

  @doc """
  Optional callback declaring which optional pack a rule belongs to.
  Defaults to `:core` when not implemented.
  """
  @callback pack() :: pack()

  @doc """
  Optional callback declaring which cleanup-guide pass (1..14) the rule
  addresses. When absent, the rule is resolved against `Archdo.CleanupPass`'s
  curated mapping table, falling back to `nil`.

  See: comprehensive_elixir_codebase_cleanup_guide.md
  """
  @callback cleanup_pass() :: 1..14 | nil

  @optional_callbacks [pack: 0, cleanup_pass: 0]

  @doc """
  Resolve a rule module's pack — `:core` if `pack/0` is not implemented,
  otherwise the value the module returns.

  Raises `ArgumentError` if the module is not loadable as an `Archdo.Rule`.
  """
  @spec pack_of(module()) :: pack()
  def pack_of(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    case function_exported?(module, :pack, 0) do
      true -> module.pack()
      false -> :core
    end
  end

  def pack_of(other) do
    raise ArgumentError, "expected a rule module, got: #{inspect(other)}"
  end

  @doc """
  All pack identifiers known to Archdo. Used by `--list-packs` and
  configuration validation.
  """
  @spec known_packs() :: [pack(), ...]
  def known_packs, do: @known_packs
end
