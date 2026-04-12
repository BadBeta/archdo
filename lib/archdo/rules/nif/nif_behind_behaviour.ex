defmodule Archdo.Rules.NIF.NifBehindBehaviour do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "11.1"

  @impl true
  def description, do: "NIF modules should implement a behaviour for replaceability/testing"

  @impl true
  def analyze(file, ast, _opts) do
    if nif_module?(ast) and not implements_behaviour?(ast) do
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
              summary: "Define a behaviour with the operations and `@behaviour` it from the NIF module",
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
    else
      []
    end
  end

  defp nif_module?(ast) do
    AST.contains?(ast, fn
      # use Rustler
      {:use, _, [{:__aliases__, _, [:Rustler]} | _]} -> true
      # use Zig (Zigler)
      {:use, _, [{:__aliases__, _, [:Zig]} | _]} -> true
      # @on_load :load_nif
      {:@, _, [{:on_load, _, _}]} -> true
      # :erlang.load_nif
      {{:., _, [:erlang, :load_nif]}, _, _} -> true
      _ -> false
    end)
  end

  defp implements_behaviour?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:behaviour, _, _}]} -> true
      _ -> false
    end)
  end

end
