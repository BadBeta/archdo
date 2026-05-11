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
      output =
        capture_io(fn ->
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

    test "includes per-rule see-also pointer for OTP rule (5.x)" do
      output =
        capture_io(fn -> Formatter.format([@sample_diag], format: :text) end)

      assert output =~ "see also:"
      assert output =~ "elixir-implementing"
    end

    test "includes per-rule see-also pointer for NIF rule (11.x)" do
      nif_diag =
        Diagnostic.warning("11.1",
          title: "NIF without behaviour",
          message: "x",
          why: "y",
          file: "lib/n.ex",
          line: 1
        )

      output = capture_io(fn -> Formatter.format([nif_diag], format: :text) end)
      assert output =~ "see also:"
      assert output =~ "rust-nif"
    end
  end

  describe ":passed channel" do
    @passed_diag Diagnostic.info("4.8",
                   title: "Project mockability summary",
                   message: "fully mockable",
                   why: "all good",
                   tags: [:passed],
                   file: "project",
                   line: 0
                 )

    test "summary format separates passed from info in tally" do
      output = capture_io(fn -> Formatter.format([@passed_diag], format: :summary) end)
      assert output =~ "0 info"
      assert output =~ "1 passed"
    end

    test "summary format omits :passed-tagged findings from the rule table" do
      output = capture_io(fn -> Formatter.format([@passed_diag], format: :summary) end)
      refute output =~ "Project mockability summary"
    end

    test "text format still shows :passed findings (they're informational)" do
      output = capture_io(fn -> Formatter.format([@passed_diag], format: :text) end)
      assert output =~ "Project mockability summary"
    end

    test "brief format omits :passed findings from output but counts them" do
      output = capture_io(fn -> Formatter.format([@passed_diag], format: :brief) end)
      refute output =~ "Project mockability summary"
      assert output =~ "1 passed"
    end
  end

  describe ":brief format" do
    @info_diag Diagnostic.info("4.8",
                 title: "Mockability",
                 message: "fully mockable",
                 why: "explanation",
                 file: "project",
                 line: 0
               )

    test "renders warn diagnostics with fixes" do
      output = capture_io(fn -> Formatter.format([@sample_diag], format: :brief) end)
      assert output =~ "5.14"
      assert output =~ "Silent handle_info catch-all"
      assert output =~ "fixes:"
      assert output =~ "Delete the catch-all"
    end

    test "elides info detail (no why/fixes blocks for info)" do
      output = capture_io(fn -> Formatter.format([@info_diag], format: :brief) end)
      refute output =~ "explanation"
      refute output =~ "fixes:"
      assert output =~ "0 errors, 0 warnings, 1 info"
    end

    test "exit code matches text format semantics" do
      capture_io(fn ->
        send(self(), {:exit_code, Formatter.format([@sample_diag], format: :brief)})
      end)

      assert_received {:exit_code, 1}
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

    test "includes confidence field in NDJSON diagnostic" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :llm)
        end)

      diagnostic =
        output
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["type"] == "diagnostic"))

      assert diagnostic["confidence"] == "high"
    end
  end

  describe "coverage signpost footer" do
    @coverage_notes [
      %{
        rule_id: "1.29",
        units_affected: 77,
        total_units: 130,
        coverage_rate: 0.5923076923076923
      }
    ]

    test "summary footer lists rules whose coverage rate triggered downgrade" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :summary, coverage_notes: @coverage_notes)
        end)

      assert output =~ "Notes"
      assert output =~ "1.29"
      assert output =~ "77"
      assert output =~ "130"
      assert output =~ "59"
    end

    test "text footer includes the signpost block" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :text, coverage_notes: @coverage_notes)
        end)

      assert output =~ "Notes"
      assert output =~ "1.29"
    end

    test "compact footer includes the signpost block" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :compact, coverage_notes: @coverage_notes)
        end)

      assert output =~ "Notes"
      assert output =~ "1.29"
    end

    test "no footer when coverage_notes is empty" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :summary, coverage_notes: [])
        end)

      refute output =~ "Notes:"
    end

    test "no footer when coverage_notes is absent" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :summary)
        end)

      refute output =~ "Notes:"
    end

    test "json format includes coverage_notes in the output" do
      output =
        capture_io(fn ->
          Formatter.format([@sample_diag], format: :json, coverage_notes: @coverage_notes)
        end)

      parsed = Jason.decode!(output)
      assert parsed["coverage_notes"] |> hd() |> Map.get("rule_id") == "1.29"
    end
  end
end
