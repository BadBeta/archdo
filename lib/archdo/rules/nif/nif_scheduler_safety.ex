defmodule Archdo.Rules.NIF.NifSchedulerSafety do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "11.2"

  @impl true
  def description, do: "NIFs processing variable-size input should use dirty schedulers"

  @impl true
  def analyze(file, ast, _opts) do
    if nif_module?(ast) do
      check_for_dirty_scheduling(file, ast)
    else
      []
    end
  end

  defp check_for_dirty_scheduling(file, ast) do
    # Check if any NIF function stubs accept binary/list arguments
    # without dirty scheduler configuration
    nif_stubs = find_nif_stubs(ast)
    has_dirty_config? = has_dirty_scheduler_config?(ast)

    if nif_stubs != [] and not has_dirty_config? do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.warning("11.2",
          title: "NIF without dirty scheduler config",
          message: "NIF module #{module_name} has stub functions but no dirty scheduler configuration",
          why:
            "Regular NIFs run on the BEAM's normal schedulers. Anything that takes more than ~1ms blocks " <>
              "the scheduler and prevents thousands of other processes from making progress. Operations on " <>
              "user-supplied binaries or lists can vary wildly in size, and a slow run starves the entire VM. " <>
              "Dirty schedulers give the BEAM dedicated threads for these operations, isolating them from the " <>
              "real-time guarantees the rest of the system relies on.",
          alternatives: [
            Fix.new(
              summary: "Mark the NIF as DirtyCpu (Rustler) or `dirty: :cpu` (Zigler)",
              detail:
                "For Rustler, add `schedule = \"DirtyCpu\"` to the `#[rustler::nif]` attribute. For Zigler, " <>
                  "add `dirty: :cpu` to the `@nif` attribute. CPU-bound NIFs run on the dirty CPU schedulers " <>
                  "and don't block normal schedulers.",
              example: """
              ```rust
              #[rustler::nif(schedule = "DirtyCpu")]
              fn process(input: Binary) -> Term { ... }
              ```
              """,
              applies_when: "The NIF is CPU-bound."
            ),
            Fix.new(
              summary: "Mark the NIF as DirtyIo for I/O-bound operations",
              detail:
                "If the NIF blocks on file or network I/O (rare — usually a Port is better), use the dirty " <>
                  "I/O schedulers instead.",
              applies_when: "The NIF is I/O-bound."
            ),
            Fix.new(
              summary: "Replace the NIF with a Port if safety is more important than latency",
              detail:
                "Ports run in a separate OS process — crashes don't take down the BEAM and there's no scheduler " <>
                  "concern at all. They cost more per call than NIFs but eliminate the safety class entirely.",
              applies_when: "Latency is not the bottleneck and crash isolation matters more."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#11.2"],
          context: %{module: module_name},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp find_nif_stubs(ast) do
    # Find functions that raise :nif_not_loaded (standard NIF stub pattern)
    AST.find_all(ast, fn
      {:def, _, [{_name, _, _args}, [do: body]]} ->
        AST.contains?(body, fn
          {:raise, _, [msg]} when is_binary(msg) -> String.contains?(msg, "NIF")
          {:raise, _, [{:__block__, _, [msg]}]} when is_binary(msg) -> String.contains?(msg, "NIF")
          {:nif_error, _, _} -> true
          {{:., _, [:erlang, :nif_error]}, _, _} -> true
          _ -> false
        end)
      _ -> false
    end)
  end

  defp has_dirty_scheduler_config?(ast) do
    file_content = ast_to_rough_string(ast)

    # Rustler: schedule = "DirtyCpu" or schedule = "DirtyIo"
    String.contains?(file_content, "DirtyCpu") or
      String.contains?(file_content, "DirtyIo") or
      # Zigler: dirty: :cpu or dirty: :io
      String.contains?(file_content, "dirty:")
  end

  defp ast_to_rough_string(ast) do
    Macro.to_string(ast)
  rescue
    _ -> ""
  end

  defp nif_module?(ast), do: AST.nif_module?(ast)
end
