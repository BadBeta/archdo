defmodule Archdo.Fix do
  @moduledoc """
  Suggested-fix struct attached to every Diagnostic via `:alternatives`.

  Each rule emits one or more `Fix` structs explaining how to address
  the finding. A Fix has:

    * `summary`      — one-line description ("Replace X with Y")
    * `detail`       — multi-line rationale and steps
    * `example`      — optional code-block example (markdown-formatted)
    * `applies_when` — optional precondition for when the fix is the
                       right move (other Fix structs in the same
                       diagnostic may apply otherwise)

  This module is the canonical Fix shape for every rule across
  `Archdo.Rules.*`. Public API for rule writers; the struct itself is
  the contract.
  """

  @type t :: %__MODULE__{
          summary: String.t(),
          detail: String.t(),
          example: String.t() | nil,
          applies_when: String.t() | nil
        }

  @enforce_keys [:summary, :detail]
  defstruct [:summary, :detail, :example, :applies_when]

  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc "Convert a Fix struct to a plain map for JSON serialization."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = fix) do
    %{
      summary: fix.summary,
      detail: fix.detail,
      example: fix.example,
      applies_when: fix.applies_when
    }
  end
end
