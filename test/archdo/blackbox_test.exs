defmodule Archdo.BlackboxTest do
  use ExUnit.Case, async: true

  alias Archdo.Blackbox

  defp parse_def(code) do
    {:ok, ast} = Code.string_to_quoted(code)
    ast
  end

  # Convenience helper retained for future tests; underscore-prefix to
  # quiet the "unused" warning until a test exercises it.
  defp _possibility(code) do
    code
    |> parse_def()
    |> Blackbox.possibility()
  end

  describe "possibility/1 — per-component scoring" do
    test "trivial pure function scores 1.0 (all components present)" do
      ast =
        parse_def("""
        defmodule M do
          @spec double(integer()) :: integer()
          def double(x), do: x * 2
        end
        """)

      [{_name, _arity, score, _components}] = Blackbox.score_module(ast)
      assert score == 1.0
    end

    test "Application.get_env in body lowers input-closure score" do
      ast =
        parse_def("""
        defmodule M do
          @spec ttl() :: integer()
          def ttl, do: Application.get_env(:my_app, :ttl)
        end
        """)

      [{_, _, score, components}] = Blackbox.score_module(ast)
      assert components.input_closure < 1.0
      assert score < 1.0
    end

    test "DateTime.utc_now in body forces determinism to 0" do
      ast =
        parse_def("""
        defmodule M do
          @spec stamp() :: DateTime.t()
          def stamp, do: DateTime.utc_now()
        end
        """)

      [{_, _, score, components}] = Blackbox.score_module(ast)
      assert components.determinism == 0.0
      assert score == 0.0
    end

    test "Logger.info in body forces side-effect-freedom to 0" do
      ast =
        parse_def("""
        defmodule M do
          @spec log(String.t()) :: :ok
          def log(msg) do
            Logger.info(msg)
            :ok
          end
        end
        """)

      [{_, _, score, components}] = Blackbox.score_module(ast)
      assert components.side_effect_free == 0.0
      assert score == 0.0
    end

    test "raise in body forces errors-as-values to 0 (non-bang function)" do
      ast =
        parse_def("""
        defmodule M do
          @spec validate(integer()) :: :ok
          def validate(x) when x < 0, do: raise(ArgumentError, "negative")
          def validate(_), do: :ok
        end
        """)

      # Multi-clause function — each clause is scored independently.
      # The clause with raise has errors_as_values 0.
      results = Blackbox.score_module(ast)
      raising_clause = Enum.find(results, fn {_, _, _, c} -> c.errors_as_values == 0.0 end)
      assert raising_clause != nil
      {_, _, score, _} = raising_clause
      assert score == 0.0
    end

    test "missing @spec drops output_completeness to 0.0" do
      ast =
        parse_def("""
        defmodule M do
          def double(x), do: x * 2
        end
        """)

      [{_, _, _score, components}] = Blackbox.score_module(ast)
      assert components.output_completeness == 0.0
    end
  end

  describe "totality (M-Aux4 real check)" do
    test "single-clause function with no pattern in head scores totality 1.0" do
      ast =
        parse_def("""
        defmodule M do
          @spec f(integer()) :: integer()
          def f(x), do: x * 2
        end
        """)

      [{_, _, _, components}] = Blackbox.score_module(ast)
      assert components.totality == 1.0
    end

    test "multi-clause function WITH catch-all scores totality 1.0" do
      ast =
        parse_def("""
        defmodule M do
          @spec f(any()) :: integer()
          def f(:a), do: 1
          def f(:b), do: 2
          def f(_), do: 0
        end
        """)

      results = Blackbox.score_module(ast)
      assert Enum.all?(results, fn {_, _, _, c} -> c.totality == 1.0 end)
    end

    test "multi-clause function WITHOUT catch-all scores totality 0.5" do
      ast =
        parse_def("""
        defmodule M do
          @spec f(:a | :b) :: integer()
          def f(:a), do: 1
          def f(:b), do: 2
        end
        """)

      results = Blackbox.score_module(ast)
      assert Enum.any?(results, fn {_, _, _, c} -> c.totality == 0.5 end)
    end
  end

  describe "module_verdict/1 (M-Aux4 — min not mean)" do
    test "all-pure module returns :building_block" do
      ast =
        parse_def("""
        defmodule M do
          @spec a(integer()) :: integer()
          def a(x), do: x
          @spec b(integer()) :: integer()
          def b(x), do: x * 2
        end
        """)

      assert Blackbox.module_verdict(ast) == :building_block
    end

    test "module with one impure function returns {:leaks_at, ...}" do
      ast =
        parse_def("""
        defmodule M do
          @spec a(integer()) :: integer()
          def a(x), do: x
          @spec b(integer()) :: :ok
          def b(_x) do
            Logger.info("leak")
            :ok
          end
        end
        """)

      assert {:leaks_at, leaks} = Blackbox.module_verdict(ast)
      assert Enum.any?(leaks, fn {name, _arity, _score} -> name == :b end)
    end

    test "module with no public functions is vacuously a building block" do
      ast =
        parse_def("""
        defmodule M do
          @moduledoc false
          defp internal(x), do: x
        end
        """)

      assert Blackbox.module_verdict(ast) == :building_block
    end
  end

  describe "context_verdict/2 (M-Aux4 — namespace aggregation)" do
    test "context with all-pure modules returns :building_block" do
      file_asts = [
        {"lib/myapp/accounts.ex",
         elem(
           Code.string_to_quoted("""
           defmodule MyApp.Accounts do
             @spec name(map()) :: String.t()
             def name(u), do: u.name
           end
           """),
           1
         )},
        {"lib/myapp/accounts/user.ex",
         elem(
           Code.string_to_quoted("""
           defmodule MyApp.Accounts.User do
             @spec greet(map()) :: String.t()
             def greet(u), do: "hi " <> u.name
           end
           """),
           1
         )}
      ]

      assert Blackbox.context_verdict(file_asts, "MyApp.Accounts") == :building_block
    end

    test "context with one impure module returns {:leaks_at, modules}" do
      file_asts = [
        {"lib/myapp/accounts.ex",
         elem(
           Code.string_to_quoted("""
           defmodule MyApp.Accounts do
             @spec name(map()) :: String.t()
             def name(u), do: u.name
           end
           """),
           1
         )},
        {"lib/myapp/accounts/audit.ex",
         elem(
           Code.string_to_quoted("""
           defmodule MyApp.Accounts.Audit do
             @spec record(map()) :: :ok
             def record(_event) do
               Logger.info("audit")
               :ok
             end
           end
           """),
           1
         )}
      ]

      assert {:leaks_at, modules} = Blackbox.context_verdict(file_asts, "MyApp.Accounts")
      assert "MyApp.Accounts.Audit" in modules
      refute "MyApp.Accounts" in modules
    end
  end

  describe "classify/1" do
    test "≥ 0.9 → :building_block" do
      assert Blackbox.classify(1.0) == :building_block
      assert Blackbox.classify(0.95) == :building_block
    end

    test "0.7–0.9 → :near_block" do
      assert Blackbox.classify(0.8) == :near_block
      assert Blackbox.classify(0.7) == :near_block
    end

    test "0.4–0.7 → :mixed" do
      assert Blackbox.classify(0.5) == :mixed
    end

    test "< 0.4 → :boundary" do
      assert Blackbox.classify(0.0) == :boundary
      assert Blackbox.classify(0.39) == :boundary
    end
  end
end
