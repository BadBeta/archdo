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
    test "module with zero public functions returns :no_public_api (not :building_block)" do
      # Validated against ash_hq — Ash Resource modules
      # (`use Ash.Resource`) have ZERO public defs at the AST level
      # (the DSL generates code at compile time). Returning
      # :building_block vacuously was misleading: the audit listed
      # 38 of 108 modules as "building blocks" when most were just
      # DSL configurations with nothing to score. A module hasn't
      # demonstrated building-block-ness if it has no public
      # function to demonstrate it.
      ast =
        parse_def("""
        defmodule M do
          use Ash.Resource
        end
        """)

      assert Blackbox.module_verdict(ast) == :no_public_api
    end

    test "all-pure module returns :building_block" do
      # M-Plan6: combined verdict now requires input safety. Guards
      # constrain the input domain, satisfying the InputGuard check.
      ast =
        parse_def("""
        defmodule M do
          @spec a(integer()) :: integer()
          def a(x) when is_integer(x), do: x
          @spec b(integer()) :: integer()
          def b(x) when is_integer(x), do: x * 2
        end
        """)

      assert Blackbox.module_verdict(ast) == :building_block
    end

    test "module with one impure function returns {:leaks_at, ...}" do
      ast =
        parse_def("""
        defmodule M do
          @spec a(integer()) :: integer()
          def a(x) when is_integer(x), do: x
          @spec b(integer()) :: :ok
          def b(_x) do
            Logger.info("leak")
            :ok
          end
        end
        """)

      assert {:leaks_at, leaks} = Blackbox.module_verdict(ast)
      assert Enum.any?(leaks, fn {name, _arity, _reason} -> name == :b end)
    end

    test "module with no public functions returns :no_public_api (not :building_block)" do
      # M-CG93 (validated against ash_hq): an empty module hasn't
      # demonstrated building-block status — it's a DSL config,
      # behaviour declaration, or all-private helper. Reporting
      # :building_block vacuously was misleading.
      ast =
        parse_def("""
        defmodule M do
          @moduledoc false
          defp internal(x), do: x
        end
        """)

      assert Blackbox.module_verdict(ast) == :no_public_api
    end

    test "M-Plan6: pure module with guarded inputs is :building_block" do
      ast =
        parse_def("""
        defmodule M do
          @spec a(integer()) :: integer()
          def a(x) when is_integer(x), do: x

          @spec b(integer(), integer()) :: integer()
          def b(x, y) when is_integer(x) and is_integer(y), do: x + y
        end
        """)

      assert Blackbox.module_verdict(ast) == :building_block
    end

    test "M-Plan6: pure module with one unguarded fn leaks via :unguarded_input" do
      # `def a(x), do: x * 2` is structurally pure but accepts any x —
      # `a("foo")` crashes deep with ArithmeticError. The verdict
      # must surface this as an input-safety leak.
      ast =
        parse_def("""
        defmodule M do
          @spec a(integer()) :: integer()
          def a(x), do: x * 2

          @spec b(integer()) :: integer()
          def b(x) when is_integer(x), do: x + 1
        end
        """)

      assert {:leaks_at, leaks} = Blackbox.module_verdict(ast)

      assert Enum.any?(leaks, fn
               {:a, 1, :unguarded_input} -> true
               _ -> false
             end),
             "expected {:a, 1, :unguarded_input} in leaks, got #{inspect(leaks)}"
    end
  end

  describe "context_verdict/2 (M-Aux4 — namespace aggregation)" do
    test "context with all-pure modules returns :building_block" do
      # M-Plan6: input-safety added — fixtures use guards to satisfy
      # the combined verdict.
      file_asts = [
        {"lib/myapp/accounts.ex",
         elem(
           Code.string_to_quoted("""
           defmodule MyApp.Accounts do
             @spec name(map()) :: String.t()
             def name(u) when is_map(u), do: u.name
           end
           """),
           1
         )},
        {"lib/myapp/accounts/user.ex",
         elem(
           Code.string_to_quoted("""
           defmodule MyApp.Accounts.User do
             @spec greet(map()) :: String.t()
             def greet(u) when is_map(u), do: "hi " <> u.name
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
             def name(u) when is_map(u), do: u.name
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

  describe "boundary_suggestion/1 (M-Aux5)" do
    test "all-pure module returns :building_block (no suggestion needed)" do
      ast =
        parse_def("""
        defmodule M do
          @spec a(integer()) :: integer()
          def a(x), do: x
          @spec b(integer()) :: integer()
          def b(x), do: x * 2
        end
        """)

      assert Blackbox.boundary_suggestion(ast) == :building_block
    end

    test "mixed module where pure fns DON'T call leaky → {:extract, ...}" do
      ast =
        parse_def("""
        defmodule M do
          @spec a(integer()) :: integer()
          def a(x), do: x * 2
          @spec b(integer()) :: integer()
          def b(x), do: x + 1
          @spec c(:ok) :: :ok
          def c(_x) do
            Logger.info("leak")
            :ok
          end
        end
        """)

      assert {:extract, leaky, pure} = Blackbox.boundary_suggestion(ast)
      assert {:c, 1} in leaky
      assert {:a, 1} in pure
      assert {:b, 1} in pure
    end

    test "mixed module where a pure fn CALLS a leaky fn → :refactor_in_place" do
      ast =
        parse_def("""
        defmodule M do
          @spec a(integer()) :: integer()
          def a(x), do: b(x) + 1
          @spec b(integer()) :: integer()
          def b(_x) do
            Logger.info("leak from b")
            42
          end
        end
        """)

      # a/1 scores high structurally, but it calls b/1 which leaks.
      # Cannot cleanly extract; recommend refactor in place.
      assert {:refactor_in_place, breakdown} = Blackbox.boundary_suggestion(ast)
      assert is_map(breakdown)
    end

    test "all-leaky module → :refactor_in_place" do
      ast =
        parse_def("""
        defmodule M do
          @spec a(:ok) :: :ok
          def a(_) do
            Logger.info("a leak")
            :ok
          end
          @spec b(:ok) :: :ok
          def b(_) do
            Logger.error("b leak")
            :ok
          end
        end
        """)

      assert {:refactor_in_place, breakdown} = Blackbox.boundary_suggestion(ast)
      # side_effect_free is the dominating failed component
      assert breakdown[:side_effect_free] >= 2
    end

    test "module with no public functions returns :building_block" do
      ast =
        parse_def("""
        defmodule M do
          @moduledoc false
        end
        """)

      assert Blackbox.boundary_suggestion(ast) == :building_block
    end
  end

  describe "refactor_distance/1 (M-Aux5)" do
    test "building-block module has distance 0" do
      ast =
        parse_def("""
        defmodule M do
          @spec a(integer()) :: integer()
          def a(x), do: x
        end
        """)

      assert Blackbox.refactor_distance(ast) == 0
    end

    test "single-component leak counts as 1" do
      ast =
        parse_def("""
        defmodule M do
          def a(x), do: x
        end
        """)

      # missing @spec → output_completeness fails → distance 1
      assert Blackbox.refactor_distance(ast) == 1
    end

    test "multiple components failed across multiple functions sum" do
      ast =
        parse_def("""
        defmodule M do
          def a(_x) do
            Logger.info("leak")
            :ok
          end
          def b(_x) do
            DateTime.utc_now()
          end
        end
        """)

      # a: missing @spec + side-effect = 2 failures
      # b: missing @spec + non-determinism = 2 failures
      # total: 4
      assert Blackbox.refactor_distance(ast) == 4
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

  describe "value_for_function/5 — context-aware value scoring" do
    # Helper: produce a substantial-body AST (≥ @substance_threshold = 30 nodes).
    defp substantial_body do
      quote do
        a = compute_x(input)
        b = compute_y(a)
        c = compute_z(b)
        d = compute_w(c)
        e = combine(a, b, c, d)
        f = transform(e)
        finalize(f)
      end
    end

    test "regular function with substantial body returns standard value (high)" do
      v = Blackbox.value_for_function(substantial_body(), :process, 1, :context, MapSet.new())
      assert v >= 0.7, "expected high value for substantial fn in context layer, got #{v}"
    end

    test "bang function (`!`-suffixed name) drops to 0.0 — bang IS the contract" do
      # `insert!/3`-shape: substantial body, but the bang declares
      # 'I raise on error' which intentionally fails errors_as_values.
      # Building-block-value of the bang variant is low by design; the
      # non-bang sibling is the building-block candidate, not the bang.
      v = Blackbox.value_for_function(substantial_body(), :insert!, 3, :context, MapSet.new())
      assert v == 0.0
    end

    test "behaviour-callback implementation drops to 0.0 — signature is dictated by the behaviour" do
      # `@impl true def insert_job/3`: signature dictated by the
      # @behaviour, not designed for composition. The behaviour IS the
      # building-block contract; the implementation is the impure
      # adapter. Building-block-value of the implementation is low.
      impls = MapSet.new([{:insert_job, 3}])

      v = Blackbox.value_for_function(substantial_body(), :insert_job, 3, :context, impls)
      assert v == 0.0
    end

    test "non-impl function on a module that ALSO has impls keeps standard value" do
      # If a module implements a behaviour AND also exposes other
      # public functions, only the impl-marked ones drop. Other
      # public fns are scored normally.
      impls = MapSet.new([{:insert_job, 3}])

      v =
        Blackbox.value_for_function(
          substantial_body(),
          :public_helper,
          1,
          :context,
          impls
        )

      assert v >= 0.7
    end

    test "orchestrator-named function still scores 0.0 (existing behaviour preserved)" do
      v = Blackbox.value_for_function(substantial_body(), :handle_call, 3, :context, MapSet.new())
      assert v == 0.0
    end

    test "trivial body in non-context layer scores 0.0 — no substance, no layer boost" do
      tiny = quote do: x * 2
      v = Blackbox.value_for_function(tiny, :double, 1, nil, MapSet.new())
      assert v == 0.0
    end

    test "trivial body in :context layer keeps the 0.2 layer boost (low band)" do
      tiny = quote do: x * 2
      v = Blackbox.value_for_function(tiny, :double, 1, :context, MapSet.new())
      assert v == 0.2
      # Still :low band — won't fire CE-54.
      assert Blackbox.value_class(v) == :low
    end
  end
end
