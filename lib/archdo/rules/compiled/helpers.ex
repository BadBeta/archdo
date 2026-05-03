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

  @doc """
  Dispatch helper for compiled rules that scan a beam directory.

  Many rules under `Archdo.Rules.Compiled.*` share the same dispatch:
  unwrap the beam_dir from the graph; if it's a binary path, run the
  rule's scanner against it; otherwise return `[]`. This helper
  centralises that pattern so the analyze_compiled/1 wrappers across
  rules don't duplicate the case-on-beam_dir shape.
  """
  @spec with_beam_dir(Archdo.Compiled.t(), (binary() -> [Archdo.Diagnostic.t()])) ::
          [Archdo.Diagnostic.t()]
  def with_beam_dir(graph, scan_fun) when is_function(scan_fun, 1) do
    case Archdo.Compiled.beam_dir(graph) do
      beam_dir when is_binary(beam_dir) -> scan_fun.(beam_dir)
      _ -> []
    end
  end

  @doc """
  Returns true if the module defines callbacks (i.e., it's a
  behaviour definition). Behaviour-definition modules are
  implemented by other modules, not called directly — so they may
  have zero function-level outgoing calls and look orphan to
  graph-walking rules. Both rules 1.25 (OrphanModule) and 1.26
  (UnanchoredModule) share this exemption.
  """
  @spec behaviour_definition?(module(), Archdo.Compiled.t()) :: boolean()
  def behaviour_definition?(mod, graph) do
    case Map.get(Archdo.Compiled.modules(graph), mod) do
      %{callback_fns: [_ | _]} -> true
      _ -> false
    end
  end

  @doc """
  Returns true if the module is an application-entry-point shape:
  `MyApp.Application` (Application callback module) or
  `MyApp.MixProject` (Mix project module). These are runtime entry
  points started outside the source-call graph and should not be
  flagged as orphan / unanchored.
  """
  @spec application_entry_point?(module()) :: boolean()
  def application_entry_point?(mod) do
    name = Atom.to_string(mod)
    String.ends_with?(name, ".Application") or String.ends_with?(name, ".MixProject")
  end
end
