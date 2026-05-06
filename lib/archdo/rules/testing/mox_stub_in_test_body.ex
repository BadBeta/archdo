defmodule Archdo.Rules.Testing.MoxStubInTestBody do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.30"

  @impl true
  def description,
    do:
      "Mox `stub/3` directly inside a `test` block — `stub` does not verify, " <>
        "`expect/3` does"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_stub_in_test_body(file, ast)
    end
  end

  defp find_stub_in_test_body(file, ast) do
    case verify_on_exit?(ast) do
      false -> []
      true -> ast |> AST.extract_test_blocks() |> Enum.flat_map(&scan_test_block(&1, file))
    end
  end

  defp verify_on_exit?(ast) do
    AST.contains?(ast, fn
      {:setup, _, [:verify_on_exit!]} -> true
      {:setup, _, [{:__block__, _, [:verify_on_exit!]}]} -> true
      {:verify_on_exit!, _, _} -> true
      _ -> false
    end)
  end

  defp scan_test_block({_name, _meta, nil}, _file), do: []

  defp scan_test_block({name, _meta, body}, file) do
    case has_expect?(body) do
      true -> []
      false -> stub_lines(body) |> Enum.map(&build_diagnostic(file, &1, name))
    end
  end

  defp has_expect?(body) do
    AST.contains?(body, fn
      {:expect, _, args} when is_list(args) and length(args) >= 2 -> true
      {{:., _, [{:__aliases__, _, [:Mox]}, :expect]}, _, _} -> true
      _ -> false
    end)
  end

  defp stub_lines(body) do
    body
    |> AST.find_all(fn
      {:stub, _, args} when is_list(args) and length(args) == 3 -> true
      {{:., _, [{:__aliases__, _, [:Mox]}, :stub]}, _, args}
      when is_list(args) and length(args) == 3 ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn {_, meta, _} -> AST.line(meta) end)
  end

  defp test_name_string({name, _meta, _args}) when is_binary(name), do: name
  defp test_name_string(name) when is_binary(name), do: name
  defp test_name_string(_), do: "test"

  defp build_diagnostic(file, line, name) do
    Diagnostic.info("7.30",
      title: "Mox `stub/3` in test body — prefer `expect/3` for verified calls",
      message:
        "Test \"#{test_name_string(name)}\" calls `stub/3` directly in the test body, " <>
          "but the module sets `verify_on_exit!`. `stub/3` does NOT verify the call " <>
          "happened — a test that stubs and never reaches the code path still passes. " <>
          "If the test is asserting that this function IS called, use `expect/3`.",
      why:
        "`stub` provides a fallback implementation when (or if) the function is called; " <>
          "it adds no expectation. `expect` records that the function MUST be called " <>
          "(N times, exactly the matching args) and `verify_on_exit!` will fail the " <>
          "test if it wasn't. In a test body, the natural intent is usually \"assert " <>
          "this interaction happened\" — that's `expect`. `stub` belongs in `setup` for " <>
          "default behavior shared across many tests.",
      alternatives: [
        Fix.new(
          summary: "Replace `stub/3` with `expect/3` to verify the call",
          detail:
            "expect(MockClient, :fetch, fn arg ->\n" <>
              "  assert arg == \"x\"\n" <>
              "  {:ok, %{}}\n" <>
              "end)\n" <>
              "# verify_on_exit! will now fail if fetch is not called.",
          applies_when:
            "When the test asserts behavior that depends on the stubbed call happening."
        ),
        Fix.new(
          summary: "Move `stub/3` to a `setup` block if it's a default for many tests",
          detail:
            "setup do\n" <>
              "  stub(MockClient, :fetch, fn _ -> {:ok, %{}} end)\n" <>
              "  :ok\n" <>
              "end",
          applies_when: "When the stub is shared default behavior, not asserting an interaction."
        )
      ],
      references: ["elixir-implementing/SKILL.md#7.10", "elixir-implementing/SKILL.md#4.4"],
      context: %{},
      file: file,
      line: line
    )
  end
end
