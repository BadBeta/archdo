defmodule Archdo.Rules.Module.StreamOverEnumOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.99"

  @impl true
  def description, do: "Eager `Enum.*` chain over a streamy source — `Stream.*` is lazy"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_stream_opportunities(file, ast)
    end
  end

  defp find_stream_opportunities(file, ast) do
    ast
    |> AST.find_all(&pipe_root?/1)
    |> Enum.flat_map(&maybe_flag(&1, file))
  end

  # The "outermost" pipe in a chain is the one whose RHS is NOT itself
  # a pipe. We walk the chain via the LHS axis.
  defp pipe_root?({:|>, _, [_lhs, rhs]}), do: not is_pipe?(rhs)
  defp pipe_root?(_), do: false

  defp is_pipe?({:|>, _, _}), do: true
  defp is_pipe?(_), do: false

  defp maybe_flag(pipe, file) do
    {source, steps} = unfold_pipe(pipe, [])
    streamy = streamy_source?(source) or first_step_streamy?(steps)
    enum_step_count = count_eager_enum_steps(steps)

    case streamy and enum_step_count >= 3 do
      true -> [build_diagnostic(file, AST.line(pipe_meta(pipe)))]
      false -> []
    end
  end

  defp first_step_streamy?([first | _]), do: streamy_source?(first)
  defp first_step_streamy?([]), do: false

  defp pipe_meta({:|>, meta, _}), do: meta

  # Unfold `a |> b |> c |> d` into {source: a, steps: [b, c, d]}.
  # The AST is left-associative: `(((a |> b) |> c) |> d)`.
  defp unfold_pipe({:|>, _, [lhs, rhs]}, acc), do: unfold_pipe(lhs, [rhs | acc])
  defp unfold_pipe(source, acc), do: {source, acc}

  defp streamy_source?({{:., _, [{:__aliases__, _, [:File]}, :stream!]}, _, _}), do: true
  defp streamy_source?({{:., _, [{:__aliases__, _, [:IO]}, :stream]}, _, _}), do: true

  defp streamy_source?({{:., _, [{:__aliases__, _, [:Stream]}, op]}, _, _})
       when op in [:resource, :unfold, :iterate, :repeatedly, :cycle],
       do: true

  # `MyApp.Repo.stream(query)` — heuristic: any module named *Repo, fn :stream / :stream!
  defp streamy_source?({{:., _, [{:__aliases__, _, parts}, op]}, _, _})
       when op in [:stream, :stream!] do
    Enum.any?(parts, &repo_alias?/1)
  end

  defp streamy_source?(_), do: false

  defp repo_alias?(part) when is_atom(part) do
    str = Atom.to_string(part)
    str == "Repo" or String.ends_with?(str, "Repo")
  end

  defp repo_alias?(_), do: false

  # An "eager Enum step" is `Enum.<fn>(...)` — anything chained via `|>`
  # that calls into Enum on the piped value.
  defp count_eager_enum_steps(steps) do
    Enum.count(steps, &enum_call?/1)
  end

  defp enum_call?({{:., _, [{:__aliases__, _, [:Enum]}, _]}, _, _}), do: true
  defp enum_call?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.99",
      title: "`Enum.*` chain over a streamy source — use `Stream.*`",
      message:
        "A `File.stream!` / `Repo.stream` / `Stream.*` source is piped " <>
          "through 3+ eager `Enum.*` steps. Each `Enum.*` materializes the " <>
          "intermediate list — `Stream.*` keeps it lazy.",
      why:
        "The point of `File.stream!` / `Repo.stream` / `Stream.resource` is " <>
          "to process data without loading it all into memory. Piping the " <>
          "stream into eager `Enum.*` calls defeats that — each step builds " <>
          "a fully-materialized list. Replace the intermediate steps with " <>
          "`Stream.map` / `Stream.filter` / etc.; only the terminal step " <>
          "(reduce, count, into) needs to be `Enum.*`. For huge inputs the " <>
          "memory difference is order-of-magnitude.",
      alternatives: [
        Fix.new(
          summary: "Replace intermediate Enum.* calls with Stream.*",
          detail:
            "Keep the terminal step (`Enum.reduce` / `Enum.count` / " <>
              "`Enum.into`) but make every intermediate step lazy.",
          example: """
          ```elixir
          # before — fully materializes file
          path
          |> File.stream!()
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.contains?(&1, "ERROR"))
          |> Enum.count()

          # after — constant memory
          path
          |> File.stream!()
          |> Stream.map(&String.trim/1)
          |> Stream.filter(&String.contains?(&1, "ERROR"))
          |> Enum.count()
          ```
          """,
          applies_when: "The input may be large enough that memory matters."
        )
      ],
      file: file,
      line: line
    )
  end
end
