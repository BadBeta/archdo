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
end
