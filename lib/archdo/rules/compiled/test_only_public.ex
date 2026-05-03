defmodule Archdo.Rules.Compiled.TestOnlyPublic do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.Compiled
  alias Archdo.{Diagnostic, Fix}

  @impl true
  def id, do: "7.21"

  @impl true
  def description, do: "Public function only called from test files"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    modules = Compiled.modules(graph)
    callee_index = Compiled.calls_by_callee(graph)

    # Find functions that are public, have callers, but ALL callers are test modules
    modules
    |> Enum.filter(fn {mod, _info} -> not test_module?(mod) end)
    |> Enum.flat_map(&test_only_diags(&1, callee_index))
  end

  defp test_only_diags({module, info}, callee_index) do
    info.exports
    |> Enum.filter(&export_called_only_from_tests?(&1, module, callee_index))
    |> Enum.reject(fn {func, _arity} -> framework_function?(func) end)
    |> Enum.map(fn {func, arity} -> build_diagnostic(module, func, arity) end)
  end

  defp export_called_only_from_tests?({func, arity}, module, callee_index) do
    callers = Map.get(callee_index, {module, func, arity}, [])
    all_callers_test?(callers)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the empty-callers shape; only test-only when at least one caller
  # exists and all are test modules.
  defp all_callers_test?([]), do: false
  defp all_callers_test?(callers), do: Enum.all?(callers, fn c -> test_module?(elem(c.caller, 0)) end)

  defp test_module?(mod) do
    mod_str = Atom.to_string(mod)

    String.ends_with?(mod_str, "Test") or
      String.contains?(mod_str, ".Test.") or
      String.contains?(mod_str, ".TestHelper") or
      String.contains?(mod_str, ".DataCase") or
      String.contains?(mod_str, ".ConnCase") or
      String.contains?(mod_str, ".ChannelCase") or
      String.contains?(mod_str, ".FeatureCase")
  end

  defp framework_function?(func) do
    func in [
      :__struct__,
      :__schema__,
      :__changeset__,
      :__info__,
      :module_info,
      :behaviour_info,
      :__impl__,
      :__protocol__
    ]
  end

  defp build_diagnostic(module, func, arity) do
    mod_name =
      module
      |> Atom.to_string()
      |> String.replace_leading("Elixir.", "")

    Diagnostic.info("7.21",
      title: "Test-only public function",
      message: "#{mod_name}.#{func}/#{arity} is public but only called from test modules",
      why:
        "A public function that is only exercised by tests — never by production code — " <>
          "suggests the test is reaching into implementation details rather than testing " <>
          "through the public API. Consider making the function private (defp) and testing " <>
          "the behaviour through the module's public interface instead.",
      alternatives: [
        Fix.new(
          summary: "Make it private and test through the public API",
          detail:
            "Change `def #{func}` to `defp #{func}` and adjust tests to exercise " <>
              "the behaviour through #{mod_name}'s public functions.",
          applies_when: "The function is an implementation detail."
        ),
        Fix.new(
          summary: "Move to a test helper module",
          detail:
            "If the function is genuinely useful for testing, move it to " <>
              "a dedicated test support module (e.g., #{mod_name}.TestHelpers).",
          applies_when: "The function is a test utility, not business logic."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#7.21"],
      context: %{module: mod_name, function: "#{func}/#{arity}"},
      file: "lib",
      line: 0
    )
  end
end
