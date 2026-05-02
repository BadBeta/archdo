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
  end
end
