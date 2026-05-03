defmodule Archdo.Rule do
  @moduledoc """
  The `Archdo.Rule` behaviour every rule module implements.

  Required callbacks: `id/0`, `description/0`. Optional callbacks:
  `analyze/3` (per-file), `analyze_project/1,2` / `analyze_compiled/1`
  (project-level), `pack/0` (opt-in pack identifier — defaults to
  `:core`), `cleanup_pass/0` (1..14 mapping to the cleanup-guide
  pass).

  Public API for rule writers.
  """

  # Pack abstraction. Rules optionally declare
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

  # `analyze/3` is optional: project-level rules implement
  # `analyze_project/{1,2}` or `analyze_compiled/{1,2}` and have no
  # per-file work, so they have no `analyze/3` to provide. The runner
  # checks `function_exported?(rule, :analyze, 3)` before calling.
  @optional_callbacks [analyze: 3, pack: 0, cleanup_pass: 0]

  @doc """
  Resolve a rule module's pack — `:core` if `pack/0` is not implemented,
  otherwise the value the module returns.

  Raises `ArgumentError` if the module is not loadable as an `Archdo.Rule`.
  Bang-suffixed because the raise IS the contract for invalid input — the
  expected use case (passing a module atom that has been verified to
  implement the Rule behaviour) cannot fail.
  """
  @spec pack_of!(module()) :: pack()
  def pack_of!(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    case function_exported?(module, :pack, 0) do
      true -> module.pack()
      false -> :core
    end
  end

  def pack_of!(other) do
    raise ArgumentError, "expected a rule module, got: #{inspect(other)}"
  end

  @doc """
  All pack identifiers known to Archdo. Used by `--list-packs` and
  configuration validation.
  """
  @spec known_packs() :: [pack(), ...]
  def known_packs, do: @known_packs
end
