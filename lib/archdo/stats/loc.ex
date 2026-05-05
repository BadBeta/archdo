defmodule Archdo.Stats.Loc do
  @moduledoc """
  Detailed line-of-code breakdown — physical / logical / comments / blanks
  — per file. Public API consumed by `Archdo.Stats` and surfaced in
  `mix archdo --metrics`.

  - **physical** — total line count.
  - **blanks** — lines that are empty or whitespace-only.
  - **comments** — comment-only lines (line starts with `#` after
    whitespace, excluding shebang `#!` at line 1, and excluding `#`
    that appears inside a string literal on the same line).
  - **logical** — count of top-level expressions parsed from the file
    AST: `def`, `defp`, `defmodule`, `defmacro`, top-level
    expressions. Comments and `do`/`end` keywords don't contribute.
  """

  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  @type result :: %{
          physical: non_neg_integer(),
          logical: non_neg_integer(),
          comments: non_neg_integer(),
          blanks: non_neg_integer()
        }

  @empty %{physical: 0, logical: 0, comments: 0, blanks: 0}

  @doc """
  Analyze a file by path. Returns a zero-counted result on read error.
  """
  @spec analyze(Path.t()) :: result()
  def analyze(path) do
    case File.read(path) do
      {:ok, content} -> analyze_content(content)
      {:error, _} -> @empty
    end
  end

  @doc """
  Analyze the given source content directly. Useful when a file is
  already in memory or for tests.
  """
  @spec analyze_content(String.t()) :: result()
  def analyze_content(content) do
    lines = String.split(content, "\n")

    {comments, blanks} = classify_lines(lines)

    %{
      physical: length(lines),
      logical: count_logical(content),
      comments: comments,
      blanks: blanks
    }
  end

  # --- Line classification ---

  defp classify_lines(lines) do
    {comments, blanks, _} =
      Enum.reduce(lines, {0, 0, 1}, fn line, {c, b, n} ->
        {c, b} = bump(line_kind(line, n), c, b)
        {c, b, n + 1}
      end)

    {comments, blanks}
  end

  defp bump(:blank, c, b), do: {c, b + 1}
  defp bump(:comment, c, b), do: {c + 1, b}
  defp bump(_, c, b), do: {c, b}

  # §§ elixir-implementing: §2.1 — multi-clause head with guards
  # dispatches on (line text, line number); avoids cond/if for the
  # 4-way classification.
  defp line_kind(line, line_no) do
    trimmed = String.trim(line)
    classify(trimmed, line_no)
  end

  defp classify("", _line_no), do: :blank
  defp classify("#!" <> _rest, 1), do: :shebang
  defp classify("#" <> _rest, _line_no), do: :comment
  defp classify(_text, _line_no), do: :code

  # --- Logical-line counting ---

  defp count_logical(content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} -> top_level_count(ast)
      {:error, _} -> 0
    end
  end

  # Unwrap `defmodule X do BODY end` so the count reflects the module's
  # inner expressions (defs, attributes, etc.), not just "1 module".
  defp top_level_count({:defmodule, _, [_alias, [{:do, body} | _]]}),
    do: top_level_count(body)

  defp top_level_count({:__block__, _, exprs}) when is_list(exprs), do: length(exprs)
  defp top_level_count(_single_expr), do: 1
end
