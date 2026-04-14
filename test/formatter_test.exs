defmodule Archdo.FormatterTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Archdo.{Diagnostic, Fix, Formatter}

  @sample_diag Diagnostic.warning("5.14",
                 title: "Silent handle_info catch-all",
                 message: "A catch-all swallows messages",
                 why: "Bad for observability.",
                 alternatives: [
                   Fix.new(
                     summary: "Delete the catch-all",
                     detail: "Use default GenServer logging.",
                     applies_when: "Elixir 1.15+"
                   )
                 ],
                 references: ["ARCHITECTURE_RULES.md#5.14"],
                 context: %{},
                 file: "lib/my_server.ex",
                 line: 42
               )

  describe "format/2 exit codes" do
    test "returns 0 for empty diagnostics" do
      output = capture_io(fn ->
        assert 0 = Formatter.format([], format: :text)
      end)

      assert output =~ "no issues found"
    end

    test "returns 1 for warnings" do
      capture_io(fn ->
        send(self(), {:exit_code, Formatter.format([@sample_diag], format: :text)})
      end)

      assert_received {:exit_code, 1}
    end

    test "returns 2 for errors" do
      error_diag =
        Diagnostic.error("99.1",
          title: "Critical",
          message: "Boom",
          why: "Bad",
          file: "lib/x.ex",
          line: 1
        )

      capture_io(fn ->
        send(self(), {:exit_code, Formatter.format([error_diag], format: :text)})
      end)

      assert_received {:exit_code, 2}
    end
  end

  describe ":text format" do
    test "includes rule id, title, message, file, and line" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :text)
        end)

      assert output =~ "5.14"
      assert output =~ "Silent handle_info catch-all"
      assert output =~ "catch-all swallows"
      assert output =~ "my_server.ex"
      assert output =~ "42"
    end

    test "includes why section" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :text)
        end)

      assert output =~ "why:"
      assert output =~ "observability"
    end

    test "includes fix alternatives" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :text)
        end)

      assert output =~ "fixes:"
      assert output =~ "Delete the catch-all"
    end

    test "includes LLM instruction" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :text)
        end)

      assert output =~ "Elixir skill"
    end
  end

  describe ":compact format" do
    test "outputs one line per diagnostic" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :compact)
        end)

      lines = output |> String.split("\n") |> Enum.reject(&(&1 == ""))
      # First line is the diagnostic, rest is LLM instruction
      assert hd(lines) =~ "my_server.ex:42: warning [5.14]"
    end
  end

  describe ":json format" do
    test "outputs valid JSON with summary and diagnostics" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :json)
        end)

      assert {:ok, parsed} = Jason.decode(output)
      assert %{"summary" => summary, "diagnostics" => diags} = parsed
      assert summary["warnings"] == 1
      assert summary["total"] == 1
      assert [diag] = diags
      assert diag["rule_id"] == "5.14"
      assert diag["file"] =~ "my_server.ex"
    end
  end

  describe ":llm format" do
    test "outputs NDJSON with instruction, summary, and diagnostics" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :llm)
        end)

      lines =
        output
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&Jason.decode!/1)

      assert [instruction, summary, diagnostic] = lines
      assert instruction["type"] == "instruction"
      assert summary["type"] == "summary"
      assert summary["warnings"] == 1
      assert diagnostic["type"] == "diagnostic"
      assert diagnostic["rule_id"] == "5.14"
      assert is_binary(diagnostic["markdown"])
      assert diagnostic["markdown"] =~ "5.14"
    end
  end
end
