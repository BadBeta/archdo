defmodule Archdo.Diagnostic do
  @moduledoc """
  Project-wide diagnostic-builder API. Every rule across `Archdo.Rules.*`
  constructs findings via `error/2`, `warning/2`, `info/2`, `nitpick/2`
  — this module is the single shape every rule emits.

  Stable infrastructure: a rename or signature change here is a
  breaking change to every rule module. See
  `elixir-implementing` §10.1 (\"When an @moduledoc false module is
  widely used\") for the architectural decision behind keeping this
  at the top level.
  """

  @type severity :: :error | :warning | :info | :nitpick

  @type t :: %__MODULE__{
          rule_id: String.t(),
          severity: severity(),
          title: String.t(),
          message: String.t(),
          why: String.t(),
          alternatives: [Archdo.Fix.t()],
          references: [String.t()],
          file: String.t(),
          line: non_neg_integer(),
          context: map(),
          tags: [atom()]
        }

  @enforce_keys [:rule_id, :severity, :title, :message, :why, :file, :line]
  defstruct [
    :rule_id,
    :severity,
    :title,
    :message,
    :why,
    :file,
    alternatives: [],
    references: [],
    context: %{},
    tags: [],
    line: 0
  ]

  @doc """
  Build a diagnostic from a keyword list. Prefer `error/2`, `warning/2`, `info/2`.
  """
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc "Build an :error diagnostic."
  def error(rule_id, opts), do: build(:error, rule_id, opts)

  @doc "Build a :warning diagnostic."
  def warning(rule_id, opts), do: build(:warning, rule_id, opts)

  @doc "Build an :info diagnostic."
  def info(rule_id, opts), do: build(:info, rule_id, opts)

  @doc "Build a :nitpick diagnostic — take-it-or-leave-it style finding."
  def nitpick(rule_id, opts), do: build(:nitpick, rule_id, opts)

  defp build(severity, rule_id, opts) do
    struct!(__MODULE__, [{:rule_id, rule_id}, {:severity, severity} | opts])
  end

  @doc "Returns the constructor function for a given severity."
  @spec builder_for(severity()) :: (String.t(), keyword() -> t())
  def builder_for(:error), do: &error/2
  def builder_for(:warning), do: &warning/2
  def builder_for(:info), do: &info/2
  def builder_for(:nitpick), do: &nitpick/2

  @doc "Numeric sort key for severity: error=0, warning=1, info=2, nitpick=3."
  @spec severity_order(severity()) :: 0..3
  defdelegate severity_order(severity), to: Archdo.Severity, as: :order
end
