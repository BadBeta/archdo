defmodule Archdo.Fix do
  @moduledoc false

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
