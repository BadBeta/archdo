defmodule Archdo.Rules.Module.ExceptionLaundering do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.18"

  @impl true
  def description,
    do: "Rescue catches one exception type but raises a different one — hides the original"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_laundering(file, ast)
    end
  end

  defp find_laundering(file, ast) do
    ast
    |> AST.find_all(fn
      {:rescue, clauses} when is_list(clauses) ->
        Enum.any?(clauses, &launders_exception?/1)

      _ ->
        false
    end)
    |> Enum.map(fn {:rescue, clauses} ->
      line =
        clauses
        |> Enum.filter(&launders_exception?/1)
        |> Enum.map(fn {:->, meta, _} -> AST.line(meta) end)
        |> List.first(1)

      Diagnostic.info("6.18",
        title: "Exception laundering",
        message:
          "Rescue catches an exception and raises a different one — original stacktrace is lost",
        why:
          "When a rescue clause catches ExceptionA but raises ExceptionB, the original " <>
            "stacktrace and error context are lost. Debugging becomes harder because the " <>
            "error reported at the surface doesn't match the root cause. If you need to " <>
            "wrap exceptions, use `reraise` to preserve the stacktrace, or return " <>
            "{:error, reason} to let the caller decide.",
        alternatives: [
          Fix.new(
            summary: "Use reraise/2 to preserve the original stacktrace",
            detail:
              "`rescue e in [OriginalError] -> reraise WrapperError, __STACKTRACE__` " <>
                "preserves the call chain for debugging.",
            applies_when: "You need to wrap the exception but preserve debuggability."
          ),
          Fix.new(
            summary: "Return {:error, reason} instead of raising",
            detail:
              "Convert the exception to an ok/error tuple: " <>
                "`rescue e -> {:error, Exception.message(e)}`. Let the caller decide " <>
                "whether to raise, log, or handle.",
            applies_when: "The caller should decide how to handle the failure."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#6.18"],
        context: %{},
        file: file,
        line: line
      )
    end)
  end

  # A rescue clause launders if it:
  # 1. Catches a specific exception type (not bare _)
  # 2. Raises a DIFFERENT exception in the body (not reraise)
  defp launders_exception?({:->, _, [pattern, body]}) do
    catches_specific?(pattern) and raises_different?(body) and not reraising?(body)
  end

  defp launders_exception?(_), do: false

  defp catches_specific?([{:in, _, [_, _]}]), do: true
  defp catches_specific?([{:__aliases__, _, _}]), do: true
  defp catches_specific?(_), do: false

  defp raises_different?(body) do
    AST.contains?(body, fn
      {:raise, _, _} -> true
      _ -> false
    end)
  end

  defp reraising?(body) do
    AST.contains?(body, fn
      {:reraise, _, _} -> true
      _ -> false
    end)
  end
end
