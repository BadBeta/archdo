defmodule Archdo.Rules.Compiled.Helpers do
  @moduledoc """
  Shared helper functions used across multiple compiled rules.

  Extracted to eliminate duplication between rule modules that need
  the same utility functions for analyzing BEAM abstract forms.
  """

  @doc """
  Returns true if the given function name is a framework-generated function.

  These are functions injected by Elixir/OTP macros (defstruct, defprotocol,
  use, etc.) and should generally be excluded from architectural analysis.
  """
  @spec framework_function?(atom()) :: boolean()
  def framework_function?(name) do
    name in [
      :__struct__,
      :__schema__,
      :__changeset__,
      :__impl__,
      :__protocol__,
      :__deriving__,
      :__using__,
      :__before_compile__,
      :__after_compile__,
      :behaviour_info
    ]
  end

  @doc """
  Returns true if the given function name looks auto-generated.

  Matches names starting with "__" (Elixir internal) or "MACRO-"
  (compile-time macro expansions).
  """
  @spec generated_function?(atom()) :: boolean()
  def generated_function?(name) do
    name_str = Atom.to_string(name)

    String.starts_with?(name_str, "__") or
      String.starts_with?(name_str, "MACRO-")
  end

  @doc """
  Calculates a rounded integer percentage of `used` out of `total`.

  Returns 0..100. Caller must ensure `total` is not zero.
  """
  @spec percentage(number(), number()) :: non_neg_integer()
  def percentage(used, total) do
    round(used / total * 100)
  end
end
