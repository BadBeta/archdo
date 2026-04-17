defmodule Archdo.Diagnostic do
  @moduledoc false

  @type severity :: :error | :warning | :info

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
          context: map()
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

  defp build(severity, rule_id, opts) do
    struct!(__MODULE__, [{:rule_id, rule_id}, {:severity, severity} | opts])
  end

  @doc "Numeric sort key for severity: error=0, warning=1, info=2."
  @spec severity_order(severity()) :: 0 | 1 | 2
  def severity_order(:error), do: 0
  def severity_order(:warning), do: 1
  def severity_order(:info), do: 2
end
