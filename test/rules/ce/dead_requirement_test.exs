defmodule Archdo.Rules.CE.DeadRequirementTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.DeadRequirement

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

  defp write_requirements_file(content) do
    path = Path.join(System.tmp_dir!(), "archdo_test_reqs_#{:rand.uniform(1_000_000)}.json")
    File.write!(path, content)
    on_exit_cleanup(path)
    path
  end

  defp on_exit_cleanup(path) do
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
  end

  describe "CE-33 — dead requirement (in source but not in code)" do
    test "fires for each requirement in source not referenced by @requirement" do
      reqs_file =
        write_requirements_file(~s|["REQ-1234", "REQ-1235", "REQ-1236"]|)

      file_asts = [
        parse("lib/myapp/billing.ex", ~S"""
        defmodule MyApp.Billing do
          @requirement "REQ-1234"
          def calculate(invoice), do: do_calc(invoice)
        end
        """)
      ]

      diags = DeadRequirement.analyze_project(file_asts, requirements_source: reqs_file)
      ids = Enum.map(diags, fn d -> d.context.requirement_id end)
      assert "REQ-1235" in ids
      assert "REQ-1236" in ids
      refute "REQ-1234" in ids
    end

    test "does NOT fire when requirements_source is not configured (off by default)" do
      file_asts = [
        parse("lib/myapp/util.ex", ~S"""
        defmodule MyApp.Util do
          def go(x), do: x
        end
        """)
      ]

      assert DeadRequirement.analyze_project(file_asts) == []
    end

    test "does NOT fire when source file does not exist" do
      file_asts = [parse("lib/x.ex", "defmodule X do; end")]

      diags =
        DeadRequirement.analyze_project(file_asts,
          requirements_source: "/tmp/this-does-not-exist-#{:rand.uniform(1_000_000)}.json"
        )

      assert diags == []
    end

    test "supports object-shaped requirements with status field" do
      reqs_file =
        write_requirements_file(~s|[
          {"id": "REQ-100", "status": "active"},
          {"id": "REQ-200", "status": "cancelled"},
          {"id": "REQ-300", "status": "deferred"}
        ]|)

      file_asts = [
        parse("lib/myapp/feature.ex", ~S"""
        defmodule MyApp.Feature do
          def go, do: :ok
        end
        """)
      ]

      diags = DeadRequirement.analyze_project(file_asts, requirements_source: reqs_file)
      ids = Enum.map(diags, fn d -> d.context.requirement_id end)
      # REQ-200 (cancelled) and REQ-300 (deferred) are exempt by status
      assert "REQ-100" in ids
      refute "REQ-200" in ids
      refute "REQ-300" in ids
    end

    test "@trace and @spec_ref annotations also count as references" do
      reqs_file =
        write_requirements_file(~s|["REQ-1", "REQ-2", "REQ-3"]|)

      file_asts = [
        parse("lib/myapp/a.ex", ~S"""
        defmodule MyApp.A do
          @spec_ref "REQ-1"
          def go(x), do: x
        end
        """),
        parse("lib/myapp/b.ex", ~S"""
        defmodule MyApp.B do
          @trace ["REQ-2", "REQ-3"]
          def go(x), do: x
        end
        """)
      ]

      diags = DeadRequirement.analyze_project(file_asts, requirements_source: reqs_file)
      assert diags == []
    end

    test "diagnostic is :info severity (informational only)" do
      reqs_file = write_requirements_file(~s|["REQ-99"]|)

      diags =
        DeadRequirement.analyze_project([parse("lib/x.ex", "defmodule X do; end")],
          requirements_source: reqs_file
        )

      assert [diag] = diags
      assert diag.severity == :info
    end
  end

  describe "pack assignment" do
    test "rule pack is :ce_compliance (opt-in)" do
      assert DeadRequirement.pack() == :ce_compliance
    end
  end
end
