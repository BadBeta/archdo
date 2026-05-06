defmodule Archdo.Rules.Testing.StubWithOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.33"

  @impl true
  def description,
    do: "Test file has 3+ `Mox.stub/3` calls for the same mock — use `stub_with/2`"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_groups(file, ast)
    end
  end

  defp find_groups(file, ast) do
    ast
    |> AST.find_all(&stub_call?/1)
    |> Enum.map(&extract_mock_and_meta/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(fn {mock, _meta} -> mock end)
    |> Enum.flat_map(fn {mock, entries} -> maybe_diagnose(file, mock, entries) end)
  end

  defp stub_call?({:stub, _, args}) when is_list(args) and length(args) == 3, do: true

  defp stub_call?({{:., _, [{:__aliases__, _, [:Mox]}, :stub]}, _, args})
       when is_list(args) and length(args) == 3,
       do: true

  defp stub_call?(_), do: false

  defp extract_mock_and_meta({:stub, meta, [{:__aliases__, _, parts}, _, _]}),
    do: {Module.concat(parts), meta}

  defp extract_mock_and_meta({:stub, meta, [mock, _, _]}) when is_atom(mock),
    do: {mock, meta}

  defp extract_mock_and_meta(
         {{:., _, [{:__aliases__, _, [:Mox]}, :stub]}, meta,
          [{:__aliases__, _, parts}, _, _]}
       ),
       do: {Module.concat(parts), meta}

  defp extract_mock_and_meta(_), do: nil

  defp maybe_diagnose(file, mock, [{_, meta}, _, _ | _] = entries) do
    [build_diagnostic(file, AST.line(meta), inspect(mock), count_entries(entries, 0))]
  end

  defp maybe_diagnose(_file, _mock, _entries), do: []

  defp count_entries([], n), do: n
  defp count_entries([_ | t], n), do: count_entries(t, n + 1)

  defp build_diagnostic(file, line, mock_name, count) do
    Diagnostic.info("7.33",
      title: "#{count} `stub/3` calls for #{mock_name} — consider `stub_with/2`",
      message:
        "This test file makes #{count} separate `stub/3` calls against `#{mock_name}`. " <>
          "If a real or fake implementation already implements the behaviour, " <>
          "`stub_with(#{mock_name}, MyImpl)` replaces all of them in one line and " <>
          "stays in sync as the behaviour grows.",
      why:
        "Each `stub/3` is a fresh seam that must be maintained as the behaviour evolves. " <>
          "`stub_with/2` delegates every callback to a real implementation (e.g., a stub " <>
          "module, a fake, or even the production module wrapped with assertions). When " <>
          "the behaviour adds a new callback, `stub_with` picks it up automatically; " <>
          "individual `stub/3` blocks would silently fall through to the default " <>
          "`UndefinedFunctionError` until you remember to add another stub.",
      alternatives: [
        Fix.new(
          summary: "Use `stub_with/2` with a real or fake implementation",
          detail:
            "# Define a default fake (often in test/support/):\n" <>
              "defmodule MyApp.MockClient.Fake do\n" <>
              "  @behaviour MyApp.Client\n" <>
              "  def fetch(_), do: {:ok, %{}}\n" <>
              "  def update(_, _), do: :ok\n" <>
              "  def delete(_), do: :ok\nend\n\n" <>
              "# In setup:\n" <>
              "setup do\n" <>
              "  stub_with(#{mock_name}, MyApp.MockClient.Fake)\n" <>
              "  :ok\nend",
          applies_when:
            "When most callbacks need a default implementation; per-test `expect/3` overrides remain available."
        )
      ],
      references: ["elixir-implementing/SKILL.md#4.4"],
      context: %{stub_count: count, mock: mock_name},
      file: file,
      line: line
    )
  end
end
