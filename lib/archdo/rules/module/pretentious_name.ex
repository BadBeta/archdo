defmodule Archdo.Rules.Module.PretentiousName do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # Suffixes that hide what a module actually does.
  #
  # Note: `Worker` is NOT in this list because `*Worker` is a legitimate Elixir/OTP
  # convention for job processors (Oban.Worker, Broadway processors, etc.).
  # Same for `Handler` — Commanded event handlers, Ash changes, Phoenix handlers
  # all use `*Handler` as a proper role name.
  @pretentious_suffixes ~w(Manager Helper Util Utils Service
                            Processor Utility Helpers Services)

  @impl true
  def id, do: "6.7"

  @impl true
  def description,
    do: "Pretentious module names — Manager/Helper/Util/Service hide what the module does"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      check_module_names(file, ast)
    end
  end

  defp check_module_names(file, ast) do
    {_, results} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [{:__aliases__, _, aliases} | _]} = node, acc ->
          last_part =
            aliases
            |> List.last()
            |> Atom.to_string()

          full = AST.module_name(Module.concat(aliases))

          if pretentious?(last_part) do
            diag =
              Diagnostic.info("6.7",
                title: "Pretentious module name",
                message:
                  "Module #{full} ends in `#{last_part}` — a generic suffix that doesn't describe its job",
                why:
                  "Suffixes like `Manager`, `Helper`, `Util`, `Service`, `Processor` are placeholders that " <>
                    "tell the reader nothing about what the module does. They're a sign that the module wasn't " <>
                    "named after a concept but after a vague role, and they encourage piling unrelated functions " <>
                    "into the same module because anything can be 'a helper'.",
                alternatives: [
                  Fix.new(
                    summary: "Rename the module after the concept it represents",
                    detail:
                      "Look at what the module actually does and pick a noun that captures that responsibility " <>
                        "(`InvoiceCalculator`, `PasswordHasher`, `OrderShipper`). The new name should make it " <>
                        "obvious what belongs in the module and what doesn't.",
                    applies_when: "The module has one identifiable responsibility."
                  ),
                  Fix.new(
                    summary: "Split the module if it has no single concept",
                    detail:
                      "If you can't pick a name because the module does several unrelated things, that's the " <>
                        "real problem — split it into focused modules and the naming follows naturally.",
                    applies_when: "The module mixes unrelated responsibilities."
                  )
                ],
                references: ["ARCHITECTURE_RULES.md#6.7"],
                context: %{module: full, suffix: last_part},
                file: file,
                line: AST.line(meta)
              )

            {node, [diag | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(results)
  end

  defp pretentious?(name) do
    Enum.any?(@pretentious_suffixes, fn suffix ->
      String.ends_with?(name, suffix) and name != suffix
    end)
  end
end
