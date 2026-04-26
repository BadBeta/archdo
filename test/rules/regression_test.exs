defmodule Archdo.Rules.RegressionTest do
  @moduledoc """
  Regression tests for bugs fixed during development.
  Each test documents the original bug and prevents it from returning.
  """
  use ExUnit.Case, async: true

  defp parse(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    ast
  end

  # --- Rule 6.34: Dead private function ---

  describe "6.34 regression: function captures" do
    test "does not flag private functions used via &func/N capture" do
      ast =
        parse("""
        defmodule Foo do
          def bar(items), do: Enum.map(items, &process/1)
          defp process(x), do: x + 1
        end
        """)

      diags = Archdo.Rules.Module.DeadPrivateFunction.analyze("lib/foo.ex", ast, [])
      assert diags == []
    end

    test "does not flag private functions used via &func/N with literal_encoder arity" do
      ast =
        parse("""
        defmodule Foo do
          def bar(items), do: Enum.map(items, &transform/1)
          defp transform(x), do: String.upcase(x)
        end
        """)

      diags = Archdo.Rules.Module.DeadPrivateFunction.analyze("lib/foo.ex", ast, [])
      assert diags == []
    end

    test "still flags truly unused private functions" do
      ast =
        parse("""
        defmodule Foo do
          def bar, do: :ok
          defp unused_helper, do: :never_called
        end
        """)

      diags = Archdo.Rules.Module.DeadPrivateFunction.analyze("lib/foo.ex", ast, [])
      assert [%{rule_id: "6.34", message: msg}] = diags
      assert msg =~ "unused_helper"
    end
  end

  describe "6.34 regression: metaprogrammed function names" do
    test "does not crash on unquote function names" do
      ast =
        parse("""
        defmodule Foo do
          for {fun, arity} <- [get: 1, put: 2] do
            def unquote(fun)(unquote_splicing(Macro.generate_arguments(arity, __MODULE__))) do
              :ok
            end
          end
        end
        """)

      # Should not crash — metaprogrammed names are skipped
      diags = Archdo.Rules.Module.DeadPrivateFunction.analyze("lib/foo.ex", ast, [])
      assert is_list(diags)
    end
  end

  # --- Rule 6.16: Missing rescue at boundary ---

  describe "6.16 regression: function-level catch :exit" do
    test "does not flag GenServer.call inside a function with catch :exit" do
      ast =
        parse("""
        defmodule Foo do
          def safe_call(server, msg) do
            GenServer.call(server, msg)
          catch
            :exit, _ -> {:error, :down}
          end
        end
        """)

      diags = Archdo.Rules.Module.MissingRescueAtBoundary.analyze("lib/foo.ex", ast, [])
      assert diags == []
    end

    test "still flags GenServer.call without any catch" do
      ast =
        parse("""
        defmodule Foo do
          def risky_call(server, msg) do
            GenServer.call(server, msg)
          end
        end
        """)

      diags = Archdo.Rules.Module.MissingRescueAtBoundary.analyze("lib/foo.ex", ast, [])
      assert [%{rule_id: "6.16"}] = diags
    end
  end

  # --- Rule 4.19: Missing telemetry ---

  describe "4.19 regression: :telemetry.span with literal_encoder" do
    test "detects :telemetry.span call" do
      ast =
        parse("""
        defmodule MyApp.Accounts do
          def create(attrs) do
            :telemetry.span([:my_app, :accounts, :create], %{}, fn ->
              result = do_create(attrs)
              {result, %{}}
            end)
          end
          def get(id), do: :ok
          def list, do: []
          defp do_create(_), do: :ok
        end
        """)

      # This module has telemetry — should NOT be flagged
      diags =
        Archdo.Rules.Module.MissingTelemetry.analyze_project([
          {"lib/my_app/accounts.ex", ast}
        ])

      telemetry_diags = Enum.filter(diags, &(&1.rule_id == "4.19"))
      assert telemetry_diags == []
    end
  end

  # --- Rule 4.27: Unused alias ---

  describe "4.27 regression: alias with :as option" do
    test "does not flag alias used via :as rename" do
      ast =
        parse("""
        defmodule Foo do
          alias Some.Long.Module, as: SLM
          def bar, do: SLM.call()
        end
        """)

      diags = Archdo.Rules.Boundary.UnusedAlias.analyze("lib/foo.ex", ast, [])
      assert diags == []
    end

    test "still flags genuinely unused alias" do
      ast =
        parse("""
        defmodule Foo do
          alias Some.Unused.Module
          def bar, do: :ok
        end
        """)

      diags = Archdo.Rules.Boundary.UnusedAlias.analyze("lib/foo.ex", ast, [])
      assert [%{rule_id: "4.27"}] = diags
    end
  end

  # --- Rule 6.50: Inefficient list operation ---

  describe "6.50 regression: ++ only in reduce, not flat_map" do
    test "does not flag ++ joining local variables in flat_map" do
      ast =
        parse("""
        defmodule Foo do
          def bar(items) do
            Enum.flat_map(items, fn item ->
              header = ["# " <> item.name]
              body = Enum.map(item.fields, &to_string/1)
              header ++ body
            end)
          end
        end
        """)

      diags = Archdo.Rules.Module.InefficientListOperation.analyze("lib/foo.ex", ast, [])
      concat_diags = Enum.filter(diags, &(&1.title =~ "++ in loop"))
      assert concat_diags == []
    end

    test "still flags ++ accumulator in Enum.reduce" do
      ast =
        parse("""
        defmodule Foo do
          def bar(items) do
            Enum.reduce(items, [], fn item, acc ->
              acc ++ [process(item)]
            end)
          end
        end
        """)

      diags = Archdo.Rules.Module.InefficientListOperation.analyze("lib/foo.ex", ast, [])
      concat_diags = Enum.filter(diags, fn d -> d.title =~ "++" end)
      assert length(concat_diags) > 0
    end
  end

  # --- Rule 6.36: Redundant guard recheck ---

  describe "6.36 regression: compound guard crash" do
    test "does not crash on function with compound when guard" do
      ast =
        parse("""
        defmodule Foo do
          defp bar(x) when is_list(x) and is_integer(hd(x)) do
            length(x)
          end
        end
        """)

      # Should not crash — compound guards were causing argument swap
      diags = Archdo.Rules.Module.RedundantGuardRecheck.analyze("lib/foo.ex", ast, [])
      assert is_list(diags)
    end
  end

  # --- Rules 6.15, 6.43, 6.45: Metaprogrammed function names ---

  describe "metaprogrammed function name safety" do
    test "6.15 does not crash on unquote function names" do
      ast =
        parse("""
        defmodule Foo do
          for name <- [:get, :put] do
            def unquote(name)(x), do: {:ok, x}
          end
        end
        """)

      diags = Archdo.Rules.Module.BangInOkErrorFunction.analyze("lib/foo.ex", ast, [])
      assert is_list(diags)
    end

    test "6.43 does not crash on unquote function names" do
      ast =
        parse("""
        defmodule Foo do
          for {name, arity} <- [process: 6] do
            def unquote(name)(a, b, c, d, e, f), do: :ok
          end
        end
        """)

      diags = Archdo.Rules.Module.LongParameterList.analyze("lib/foo.ex", ast, [])
      assert is_list(diags)
    end

    test "6.45 does not crash on unquote function names" do
      ast =
        parse("""
        defmodule Foo do
          for name <- [:validate, :check] do
            def unquote(name)(x), do: true
          end
        end
        """)

      diags = Archdo.Rules.Module.BooleanBlindness.analyze("lib/foo.ex", ast, [])
      assert is_list(diags)
    end
  end
end
