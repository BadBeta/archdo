defmodule Archdo.Rules.CE.ContractDensityTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.ContractDensity

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

  describe "CE-11 — irreversible decision lacks contract density" do
    test "fires on Ecto schema with sub-score below 50% of cohort median" do
      # 4 well-documented schemas + 1 bare schema → bare schema is the outlier.
      good_schema = fn name ->
        ~s|defmodule MyApp.#{name} do
          @moduledoc "Documented schema."
          use Ecto.Schema
          @spec id(map()) :: integer()
          @doc "id"
          def id(s), do: s.id
          @spec name(map()) :: String.t()
          @doc "name"
          def name(s), do: s.name
        end|
      end

      file_asts = [
        parse("lib/myapp/a.ex", good_schema.("A")),
        parse("lib/myapp/b.ex", good_schema.("B")),
        parse("lib/myapp/c.ex", good_schema.("C")),
        parse("lib/myapp/d.ex", good_schema.("D")),
        parse("lib/myapp/bare.ex", ~S"""
        defmodule MyApp.Bare do
          use Ecto.Schema

          def id(s), do: s.id
          def name(s), do: s.name
        end
        """)
      ]

      diags = ContractDensity.analyze_project(file_asts)
      assert Enum.any?(diags, fn d ->
               d.rule_id == "CE-11" and d.message =~ "MyApp.Bare"
             end)
    end

    test "does NOT fire when no irreversible-decision modules exist" do
      file_asts = [
        parse("lib/myapp/util.ex", ~S"""
        defmodule MyApp.Util do
          def a(x), do: x
          def b(x), do: x * 2
        end
        """)
      ]

      assert ContractDensity.analyze_project(file_asts) == []
    end

    test "does NOT fire when only one irreversible module exists (no cohort)" do
      # Median requires a sample; one module is degenerate — skip.
      file_asts = [
        parse("lib/myapp/lone.ex", ~S"""
        defmodule MyApp.Lone do
          use Ecto.Schema
          def id(s), do: s.id
        end
        """)
      ]

      assert ContractDensity.analyze_project(file_asts) == []
    end

    test "does NOT fire on @archdo_skip_contract_check exemption" do
      good_schema = fn name ->
        ~s|defmodule MyApp.#{name} do
          @moduledoc "Documented."
          use Ecto.Schema
          @spec id(map()) :: integer()
          @doc "id"
          def id(s), do: s.id
        end|
      end

      file_asts = [
        parse("lib/myapp/a.ex", good_schema.("A")),
        parse("lib/myapp/b.ex", good_schema.("B")),
        parse("lib/myapp/c.ex", good_schema.("C")),
        parse("lib/myapp/skipped.ex", ~S"""
        defmodule MyApp.Skipped do
          use Ecto.Schema
          @archdo_skip_contract_check "internal only"

          def id(s), do: s.id
          def name(s), do: s.name
        end
        """)
      ]

      diags = ContractDensity.analyze_project(file_asts)
      refute Enum.any?(diags, fn d -> d.message =~ "MyApp.Skipped" end)
    end

    test "names which sub-score(s) failed in the message" do
      good_schema = fn name ->
        ~s|defmodule MyApp.#{name} do
          @moduledoc "Doc."
          use Ecto.Schema
          @spec id(map()) :: integer()
          @doc "id"
          def id(s), do: s.id
        end|
      end

      file_asts = [
        parse("lib/myapp/a.ex", good_schema.("A")),
        parse("lib/myapp/b.ex", good_schema.("B")),
        parse("lib/myapp/c.ex", good_schema.("C")),
        parse("lib/myapp/bare.ex", ~S"""
        defmodule MyApp.Bare do
          use Ecto.Schema
          def id(s), do: s.id
        end
        """)
      ]

      diags = ContractDensity.analyze_project(file_asts)
      bare = Enum.find(diags, fn d -> d.message =~ "MyApp.Bare" end)
      assert bare != nil
      # Should mention spec_coverage or doc_coverage as the failed dimension
      msg = bare.message
      assert msg =~ "spec" or msg =~ "doc"
    end
  end

  describe "M-Plan10 — test_density sub-score" do
    test "fires on schema with no paired test file when others have one" do
      # Three schemas; only the first two have paired test files.
      # MyApp.Untested has spec+doc but ZERO test_density — fires
      # on the test_density dimension.
      good_schema = fn name ->
        ~s|defmodule MyApp.#{name} do
          @moduledoc "Documented schema."
          use Ecto.Schema
          @spec id(map()) :: integer()
          @doc "id"
          def id(s), do: s.id
          @spec name(map()) :: String.t()
          @doc "name"
          def name(s), do: s.name
        end|
      end

      paired_test = fn name ->
        ~s|defmodule MyApp.#{name}Test do
          use ExUnit.Case
          test "id/1 returns the id field" do
            :ok
          end
          test "name/1 returns the name field" do
            :ok
          end
        end|
      end

      file_asts = [
        parse("lib/myapp/a.ex", good_schema.("A")),
        parse("test/myapp/a_test.exs", paired_test.("A")),
        parse("lib/myapp/b.ex", good_schema.("B")),
        parse("test/myapp/b_test.exs", paired_test.("B")),
        parse("lib/myapp/c.ex", good_schema.("C")),
        parse("test/myapp/c_test.exs", paired_test.("C")),
        parse("lib/myapp/untested.ex", good_schema.("Untested"))
        # NOTE: no paired test/myapp/untested_test.exs
      ]

      diags = ContractDensity.analyze_project(file_asts)
      untested = Enum.find(diags, fn d -> d.message =~ "MyApp.Untested" end)
      assert untested != nil
      assert untested.message =~ "test"
    end

    test "fires with cohort of 2 (lowered min)" do
      # Pre-M-Plan10: required cohort ≥ 3. New: ≥ 2.
      good_schema = fn name ->
        ~s|defmodule MyApp.#{name} do
          @moduledoc "Doc."
          use Ecto.Schema
          @spec id(map()) :: integer()
          @doc "id"
          def id(s), do: s.id
        end|
      end

      paired_test = fn name ->
        ~s|defmodule MyApp.#{name}Test do
          use ExUnit.Case
          test "id" do
            :ok
          end
        end|
      end

      file_asts = [
        parse("lib/myapp/a.ex", good_schema.("A")),
        parse("test/myapp/a_test.exs", paired_test.("A")),
        parse("lib/myapp/bare.ex", ~S"""
        defmodule MyApp.Bare do
          use Ecto.Schema
          def id(s), do: s.id
        end
        """)
      ]

      diags = ContractDensity.analyze_project(file_asts)
      assert Enum.any?(diags, fn d -> d.message =~ "MyApp.Bare" end)
    end
  end
end
