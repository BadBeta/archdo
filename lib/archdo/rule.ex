defmodule Archdo.Rule do
  @moduledoc false

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
end
