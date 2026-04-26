defmodule Archdo.Rules.OTP.ProcessDictionary do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.32"

  @impl true
  def description, do: "Process dictionary (Process.put/get) — hidden state, hard to test"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_process_dict(file, ast)
    end
  end

  defp find_process_dict(file, ast) do
    Enum.map(
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, [:Process]}, func]}, _, _}
        when func in [:put, :get, :delete, :erase] ->
          true

        _ ->
          false
      end),
      fn {{:., _, [{:__aliases__, _, _}, func]}, meta, _} ->
        Diagnostic.info("5.32",
          title: "Process dictionary access",
          message: "Process.#{func} writes to or reads from the process dictionary",
          why:
            "The process dictionary is hidden mutable state. Functions that read/write it depend on a bag of " <>
              "values that doesn't appear in their arguments, which makes them impossible to test in isolation, " <>
              "impossible to reason about under refactoring, and order-dependent. Acceptable for libraries that " <>
              "explicitly own it (Logger metadata, Plug.Conn assigns) but not for domain code.",
          alternatives: [
            Fix.new(
              summary: "Pass the state explicitly through function arguments",
              detail:
                "Add the value to the function's parameter list (or to a struct passed through a pipeline). " <>
                  "Functions become pure(ish), tests get trivial, and the dependencies are visible at call sites.",
              applies_when: "The state has a natural place on the call chain."
            ),
            Fix.new(
              summary: "Move the state into a GenServer's state field",
              detail:
                "If the state needs to persist across messages, put it in the GenServer's state map and pass it " <>
                  "between callbacks the normal way. The visibility benefits are the same as explicit arguments.",
              applies_when: "The state spans multiple GenServer messages."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.32"],
          context: %{call: "Process.#{func}"},
          file: file,
          line: AST.line(meta)
        )
      end
    )
  end
end
