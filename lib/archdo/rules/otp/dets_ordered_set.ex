defmodule Archdo.Rules.OTP.DetsOrderedSet do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.46"

  @impl true
  def description,
    do: "DETS does not support :ordered_set — only :set, :bag, :duplicate_bag"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_dets_ordered_set(file, ast)
    end
  end

  defp find_dets_ordered_set(file, ast) do
    ast
    |> AST.find_all(&dets_open_with_ordered_set?/1)
    |> Enum.map(fn {_, meta, _} -> build_diagnostic(file, AST.line(meta)) end)
  end

  # Match `:dets.open_file(_name, opts)` where opts is a literal keyword
  # list containing `type: :ordered_set`. Variable-bound option lists
  # are out of scope — this is the cheap, high-precision detector.
  defp dets_open_with_ordered_set?({{:., _, [:dets, :open_file]}, _, [_name, opts]})
       when is_list(opts),
       do: ordered_set_in_opts?(opts)

  defp dets_open_with_ordered_set?(_), do: false

  defp ordered_set_in_opts?(opts), do: Enum.any?(opts, &ordered_set_pair?/1)

  # `type: :ordered_set` — bare keyword form
  defp ordered_set_pair?({:type, :ordered_set}), do: true
  # `type: :ordered_set` — atom-key wrapped, atom-value wrapped by literal_encoder
  defp ordered_set_pair?({{:__block__, _, [:type]}, {:__block__, _, [:ordered_set]}}), do: true
  defp ordered_set_pair?({:type, {:__block__, _, [:ordered_set]}}), do: true
  defp ordered_set_pair?({{:__block__, _, [:type]}, :ordered_set}), do: true
  defp ordered_set_pair?(_), do: false

  defp build_diagnostic(file, line) do
    Diagnostic.warning("5.46",
      title: "DETS does not support :ordered_set",
      message:
        ":dets.open_file/2 called with type: :ordered_set — DETS only supports " <>
          ":set, :bag, and :duplicate_bag. The call will fail at runtime.",
      why:
        "DETS table types are :set, :bag, and :duplicate_bag — there is no :ordered_set " <>
          "in DETS. Only ETS supports :ordered_set. The call crashes with " <>
          "{:error, {:badarg, ...}} at runtime, but a test that doesn't exercise this " <>
          "code path won't catch it. The bug typically lives in production until the " <>
          "feature using DETS first runs.",
      alternatives: [
        Fix.new(
          summary: "Use ETS if you need ordered access",
          detail:
            "ETS supports :ordered_set with O(log n) ordered traversal via " <>
              ":ets.first/1, :ets.next/2, :ets.prev/2. If your data fits in memory and " <>
              "you don't need on-disk persistence, ETS is the right choice.",
          applies_when: "The data fits in memory and persistence isn't required."
        ),
        Fix.new(
          summary: "Switch DETS to type: :set and sort at read time",
          detail:
            "DETS :set is unordered, but if your access pattern is occasional reads " <>
              "you can read the whole table and sort: " <>
              "`:dets.foldl(fn x, acc -> [x | acc] end, [], table) |> Enum.sort()`. " <>
              "Acceptable when the table is small.",
          applies_when: "The table is small and read-heavy."
        ),
        Fix.new(
          summary: "Use a database (Ecto) for persistent ordered storage",
          detail:
            "If the data is genuinely persistent and ordered access matters, a real " <>
              "database (PostgreSQL, SQLite via Ecto) is the right tool. DETS was " <>
              "designed for simple on-disk ETS-shaped lookups, not query workloads.",
          applies_when: "The data is large, persistent, and queries beyond ordering matter."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#5.46"],
      context: %{call: ":dets.open_file"},
      file: file,
      line: line
    )
  end
end
