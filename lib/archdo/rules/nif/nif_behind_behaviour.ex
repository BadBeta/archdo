defmodule Archdo.Rules.NIF.NifBehindBehaviour do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # File reads on NIF artifact paths IS the boundary work — this
  # rule inspects compiled NIF .so / .cpp metadata that doesn't
  # reach the AST. The file content IS the input.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  @impl true
  def id, do: "11.1"

  @impl true
  def description, do: "NIF modules should implement a behaviour for replaceability/testing"

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      not AST.nif_module?(ast) -> []
      AST.implements_behaviour?(ast) -> []
      shape_a_with_wrapper?(file, ast) -> []
      true -> diagnostic(file, ast)
    end
  end

  # Shape A (Explorer/Tokenizers/mdex): the NIF stub is `@moduledoc false` and
  # a sibling wrapper module exists at the parent file path. The wrapper is
  # the public API + test seam; the stub is intentionally raw. Adding a
  # `@behaviour` here would be ceremony with no second implementation to swap.
  defp shape_a_with_wrapper?(file, ast) do
    AST.internal_module?(ast) and File.exists?(sibling_wrapper_path(file))
  end

  defp sibling_wrapper_path(file) do
    file
    |> Path.dirname()
    |> Kernel.<>(".ex")
  end

  defp diagnostic(file, ast) do
    module_name = AST.extract_module_name(ast)

    [
      Diagnostic.warning("11.1",
        title: "NIF module without behaviour",
        message: "NIF module #{module_name} does not declare or implement a behaviour",
        why:
          "NIFs are native code that lives outside the BEAM's safety net: a crash takes the whole VM down. " <>
            "Hiding the NIF behind a behaviour gives you a clean abstraction: tests can swap in a pure Elixir " <>
            "implementation, the public surface is documented, and consumers depend on the behaviour rather " <>
            "than the unsafe native module directly.",
        alternatives: [
          Fix.new(
            summary:
              "Define a behaviour with the operations and `@behaviour` it from the NIF module",
            detail:
              "Declare `@callback foo(args) :: result` in a separate behaviour module, then add `@behaviour " <>
                "MyApp.MyNif.Behaviour` and `@impl true` markers to the NIF module. Optionally provide a " <>
                "pure Elixir fallback module that implements the same behaviour for tests.",
            applies_when: "The NIF has a small, stable surface."
          ),
          Fix.new(
            summary: "Wrap the NIF in an Elixir module that exposes the public API",
            detail:
              "Keep the NIF module raw and create a thin Elixir wrapper that handles error tuples, retries, " <>
                "and validation. The wrapper is what the rest of the codebase depends on.",
            applies_when: "You want a buffer layer between business code and the unsafe NIF."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#11.1"],
        context: %{module: module_name},
        file: file,
        line: 1
      )
    ]
  end
end
