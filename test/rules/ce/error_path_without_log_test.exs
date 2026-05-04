defmodule Archdo.Rules.CE.ErrorPathWithoutLogTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.ErrorPathWithoutLog

  describe "CE-28 — function returns {:error, _} without an in-scope log" do
    test "fires on bare error literal with no Logger call in the function" do
      code = ~S"""
      defmodule MyApp.Service do
        def call(x) do
          if x < 0 do
            {:error, :invalid}
          else
            do_work(x)
          end
        end
      end
      """

      diags = assert_flagged(ErrorPathWithoutLog, code)
      assert hd(diags).rule_id == "CE-28"
      assert hd(diags).message =~ "call/1"
    end

    test "does NOT fire when Logger is called in the same function body" do
      code = ~S"""
      defmodule MyApp.Service do
        def call(x) do
          if x < 0 do
            Logger.error("invalid input", x: x)
            {:error, :invalid}
          else
            do_work(x)
          end
        end
      end
      """

      assert_clean(ErrorPathWithoutLog, code)
    end

    test "fires on rescue block with no Logger call" do
      code = ~S"""
      defmodule MyApp.Risky do
        def go(x) do
          do_work(x)
        rescue
          e in RuntimeError -> {:error, e}
        end
      end
      """

      [diag] = assert_flagged(ErrorPathWithoutLog, code)
      assert diag.rule_id == "CE-28"
    end

    test "does NOT fire when @archdo_silent_error is set" do
      code = ~S"""
      defmodule MyApp.Domain do
        @archdo_silent_error "{:error, :not_found} is normal control flow"

        def fetch(id) do
          case lookup(id) do
            nil -> {:error, :not_found}
            v -> {:ok, v}
          end
        end
      end
      """

      assert_clean(ErrorPathWithoutLog, code)
    end

    test "does NOT fire when project has a covering log plug (M-Plan7)" do
      code = ~S"""
      defmodule MyApp.Service do
        def call(x) do
          if x < 0 do
            {:error, :invalid}
          else
            do_work(x)
          end
        end
      end
      """

      coverage = %{telemetry_plugs: [], log_plugs: ["MyAppWeb.Plugs.ErrorLog"]}

      assert_clean(ErrorPathWithoutLog, code, plug_coverage: coverage)
    end

    test "fires when project has plug_coverage but no log plugs (M-Plan7)" do
      code = ~S"""
      defmodule MyApp.Service do
        def call(x) do
          if x < 0 do
            {:error, :invalid}
          else
            do_work(x)
          end
        end
      end
      """

      coverage = %{telemetry_plugs: ["MyAppWeb.Plugs.Telemetry"], log_plugs: []}

      diags = assert_flagged(ErrorPathWithoutLog, code, plug_coverage: coverage)
      assert hd(diags).rule_id == "CE-28"
    end

    test "does NOT fire on plain ok/error pass-through (no error literal originated here)" do
      code = ~S"""
      defmodule MyApp.Pass do
        def go(x) do
          inner_call(x)
        end
      end
      """

      assert_clean(ErrorPathWithoutLog, code)
    end

    test "does NOT fire when {:error, _} appears only in case clause patterns (LHS)" do
      # `case` clause heads MATCH `{:error, _}` — they don't return it.
      # The function returns the body's last expression.
      code = ~S"""
      defmodule MyApp.Match do
        def lookup(id) do
          case fetch(id) do
            {:ok, v} -> v
            {:error, _reason} -> :not_found
          end
        end
      end
      """

      assert_clean(ErrorPathWithoutLog, code)
    end

    test "does NOT fire when {:error, _} appears only in with-else patterns (LHS)" do
      code = ~S"""
      defmodule MyApp.WithElse do
        def go(x) do
          with {:ok, a} <- step1(x),
               {:ok, b} <- step2(a) do
            {:ok, b}
          else
            {:error, msg} -> :handled
          end
        end
      end
      """

      assert_clean(ErrorPathWithoutLog, code)
    end

    test "does NOT fire when {:error, _} appears only in function-clause head (LHS)" do
      code = ~S"""
      defmodule MyApp.Heads do
        def handle({:ok, v}), do: v
        def handle({:error, _reason}), do: :default
      end
      """

      assert_clean(ErrorPathWithoutLog, code)
    end

    test "still fires when {:error, _} is constructed and returned (not just matched)" do
      # The literal IS being constructed at the return site — true positive.
      code = ~S"""
      defmodule MyApp.Returns do
        def go(x) do
          case fetch(x) do
            {:ok, v} -> {:ok, v}
            {:ok, _other} -> {:error, :unexpected}
          end
        end
      end
      """

      assert_flagged(ErrorPathWithoutLog, code)
    end
  end
end
