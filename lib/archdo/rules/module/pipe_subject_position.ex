defmodule Archdo.Rules.Module.PipeSubjectPosition do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # Argument names that signal "this is configuration / options, not the
  # subject of the pipeline." Tight set to control FP.
  @opts_names ~w(opts options config)

  # Argument names (or destructure shapes) that signal "this is the value
  # the function operates on" — the subject of a pipeline.
  @subject_names ~w(data list map subject value coll enumerable items rows)

  @impl true
  def id, do: "6.97"

  @impl true
  def description, do: "Public function arg order suggests a subject-position flip"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_subject_position_flips(file, ast)
    end
  end

  defp find_subject_position_flips(file, ast) do
    ast
    |> AST.extract_functions(:public)
    |> Enum.flat_map(&maybe_flag(&1, file))
  end

  # Two-arg public fns only. Three+ args turn into multi-subject signatures
  # (e.g. `Map.merge(a, b, conflict_fn)`) where naming heuristics can't
  # reliably identify "the subject."
  defp maybe_flag({name, 2, meta, [arg1, arg2], _body}, file) do
    case flip?(arg1, arg2) do
      true -> [build_diagnostic(file, AST.line(meta), name, 2)]
      false -> []
    end
  end

  defp maybe_flag(_, _), do: []

  defp flip?(arg1, arg2) do
    opts_arg?(arg1) and subject_arg?(arg2)
  end

  defp opts_arg?(arg) do
    case AST.arg_name(arg) do
      name when is_binary(name) -> name in @opts_names
      _ -> false
    end
  end

  # Subject is either a name from the subject list, or a struct-destructure
  # pattern (e.g. `%User{} = u`, `%User{name: name}`).
  defp subject_arg?(arg) do
    subject_named?(arg) or subject_struct_destructure?(arg)
  end

  defp subject_named?(arg) do
    case AST.arg_name(arg) do
      name when is_binary(name) -> name in @subject_names
      _ -> false
    end
  end

  # `%User{...}` or `%User{...} = bound` — Elixir AST: `{:%, _, [alias, ...]}`
  # `{:=, _, [{:%, _, [_, _]}, _]}`
  defp subject_struct_destructure?({:%, _, _}), do: true
  defp subject_struct_destructure?({:=, _, [{:%, _, _}, _]}), do: true
  defp subject_struct_destructure?(_), do: false

  defp build_diagnostic(file, line, name, arity) do
    Diagnostic.info("6.97",
      title: "Subject-position flip in public function",
      message:
        "#{name}/#{arity} takes its options first and what looks like the " <>
          "subject last — pipelines won't compose with this signature.",
      why:
        "Idiomatic Elixir puts the data being transformed FIRST. The standard " <>
          "library is rigorous: `Enum.map(coll, fn)`, `String.replace(s, " <>
          "pat, rep)`, `Map.put(map, k, v)`. Flipping the subject to the " <>
          "last position breaks pipe composition: callers can't write " <>
          "`data |> mod.fun(opts)` — they have to use `then/2` or split " <>
          "into intermediate variables. Renaming arguments is a 5-minute " <>
          "refactor that pays off in every downstream call site forever.",
      alternatives: [
        Fix.new(
          summary: "Reorder: subject first, options last",
          detail:
            "Move the data argument to position 1 and put options last. " <>
              "Default the options to `[]` if all callers pass them.",
          example: """
          ```elixir
          # before
          def transform(opts, data), do: ...

          # after
          def transform(data, opts \\\\ []), do: ...
          ```
          """,
          applies_when: "The function is part of a building-block / pure-fn API."
        ),
        Fix.new(
          summary: "Keep order if first-arg is genuinely the subject",
          detail:
            "If the first arg IS the subject (and just happens to be named " <>
              "`opts`/`config`/`options`), rename it to clarify intent " <>
              "(`schema`, `target`, `subject`).",
          applies_when: "The naming was misleading and the order is already correct."
        )
      ],
      file: file,
      line: line
    )
  end
end
