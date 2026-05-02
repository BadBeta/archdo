defmodule Archdo.Rules.CE.MissingTraceabilityTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.MissingTraceability

  defp parse(file, code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {file, ast}
  end

  describe "CE-32 — public function lacks requirement annotation" do
    test "fires on public function under traceability_required_paths without @requirement" do
      file_asts = [
        parse("lib/myapp/billing/calculator.ex", ~S"""
        defmodule MyApp.Billing.Calculator do
          def calculate(invoice), do: do_calc(invoice)
        end
        """)
      ]

      diags =
        MissingTraceability.analyze_project(file_asts,
          traceability_required_paths: ["lib/myapp/billing/"]
        )

      assert [diag] = diags
      assert diag.rule_id == "CE-32"
      assert diag.message =~ "calculate/1"
    end

    test "does NOT fire when @requirement is set at function level" do
      file_asts = [
        parse("lib/myapp/billing/calculator.ex", ~S"""
        defmodule MyApp.Billing.Calculator do
          @requirement "REQ-1234"
          def calculate(invoice), do: do_calc(invoice)
        end
        """)
      ]

      assert MissingTraceability.analyze_project(file_asts,
               traceability_required_paths: ["lib/myapp/billing/"]
             ) == []
    end

    test "does NOT fire when @requirement is set at module level (covers all functions)" do
      file_asts = [
        parse("lib/myapp/billing/calculator.ex", ~S"""
        defmodule MyApp.Billing.Calculator do
          @moduledoc "..."
          @requirement "REQ-1234"

          def calculate(invoice), do: do_calc(invoice)
          def itemize(invoice), do: do_itemize(invoice)
        end
        """)
      ]

      assert MissingTraceability.analyze_project(file_asts,
               traceability_required_paths: ["lib/myapp/billing/"]
             ) == []
    end

    test "does NOT fire when file is OUTSIDE traceability_required_paths" do
      file_asts = [
        parse("lib/myapp/util.ex", ~S"""
        defmodule MyApp.Util do
          def helper(x), do: x
        end
        """)
      ]

      assert MissingTraceability.analyze_project(file_asts,
               traceability_required_paths: ["lib/myapp/billing/"]
             ) == []
    end

    test "does NOT fire when no traceability_required_paths configured (off by default)" do
      file_asts = [
        parse("lib/myapp/billing/calculator.ex", ~S"""
        defmodule MyApp.Billing.Calculator do
          def calculate(invoice), do: do_calc(invoice)
        end
        """)
      ]

      assert MissingTraceability.analyze_project(file_asts) == []
    end

    test "accepts @spec_ref and @trace as alternatives to @requirement" do
      file_asts = [
        parse("lib/myapp/api/handler.ex", ~S"""
        defmodule MyApp.Api.Handler do
          @spec_ref "RFC 7231 §6.5.1"
          def process(req), do: do_process(req)
        end
        """)
      ]

      assert MissingTraceability.analyze_project(file_asts,
               traceability_required_paths: ["lib/myapp/api/"]
             ) == []
    end

    test "does NOT fire when @archdo_no_trace is set" do
      file_asts = [
        parse("lib/myapp/billing/scratch.ex", ~S"""
        defmodule MyApp.Billing.Scratch do
          @archdo_no_trace "temporary scaffolding — delete by 2026-Q3"

          def quick_test(x), do: x
        end
        """)
      ]

      assert MissingTraceability.analyze_project(file_asts,
               traceability_required_paths: ["lib/myapp/billing/"]
             ) == []
    end

    test "fires per-function when one is annotated and one precedes any annotation" do
      # Convention: any @requirement before any def covers the whole module.
      # To get per-function behaviour, the untraced function must come BEFORE
      # the first @requirement / def-with-@requirement pair.
      file_asts = [
        parse("lib/myapp/billing/calculator.ex", ~S"""
        defmodule MyApp.Billing.Calculator do
          def helper(x), do: x

          @requirement "REQ-1234"
          def calculate(invoice), do: do_calc(invoice)
        end
        """)
      ]

      diags =
        MissingTraceability.analyze_project(file_asts,
          traceability_required_paths: ["lib/myapp/billing/"]
        )

      assert length(diags) == 1
      assert hd(diags).message =~ "helper/1"
    end
  end

  describe "pack assignment" do
    test "rule pack is :ce_compliance (opt-in)" do
      assert MissingTraceability.pack() == :ce_compliance
    end
  end
end
