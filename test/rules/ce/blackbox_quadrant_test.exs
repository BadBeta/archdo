defmodule Archdo.Rules.CE.BlackboxQuadrantTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.BlackboxQuadrant

  describe "policy cells" do
    test "{:low, :high} fires CE-54 (substantial impure function)" do
      # Substantial body (≥ 30 AST nodes) + impure (Logger), pack
      # composability defaults active in this test.
      code = ~S"""
      defmodule MyApp.Workflow do
        @spec process(map()) :: {:ok, map()} | {:error, term()}
        def process(input) do
          case validate(input) do
            {:ok, x} ->
              y = transform(x)
              z = apply_business_rules(y)
              w = format_output(z)
              Logger.info("processed", id: w.id)
              {:ok, w}
            {:error, _} = e ->
              e
          end
        end
        defp validate(_), do: {:ok, %{}}
        defp transform(x), do: x
        defp apply_business_rules(x), do: x
        defp format_output(x), do: x
      end
      """

      diags = assert_flagged(BlackboxQuadrant, code, file: "lib/my_app/workflow.ex")
      assert hd(diags).rule_id == "CE-54"
      assert hd(diags).severity == :warning
    end

    test "{:high, :low} (trivial pure function) does NOT fire" do
      code = ~S"""
      defmodule MyApp.Plain do
        @spec double(integer()) :: integer()
        def double(x), do: x * 2
      end
      """

      assert_clean(BlackboxQuadrant, code, file: "lib/my_app/plain.ex")
    end

    test "{:low, :low} (orchestrator function — handle_event) does NOT fire" do
      code = ~S"""
      defmodule MyAppWeb.SomeLive do
        def handle_event("submit", params, socket) do
          Logger.info("submit", params: params)
          {:noreply, socket}
        end
      end
      """

      assert_clean(BlackboxQuadrant, code, file: "lib/my_app_web/some_live.ex")
    end

    test "{:high, :high} (substantial pure function with @spec) does NOT fire CE-54" do
      # Building-block already — no actionable finding from CE-54.
      # CE-55 (deferred to M-Aux) would mark it as a property-test
      # candidate, but CE-54 itself stays clean.
      code = ~S"""
      defmodule MyApp.Math do
        @spec compose(integer(), integer(), integer(), integer()) :: integer()
        def compose(a, b, c, d) do
          x = a + b
          y = c + d
          z = x * y
          w = z - a
          v = w + b
          u = v * c
          t = u - d
          t
        end
      end
      """

      assert_clean(BlackboxQuadrant, code, file: "lib/my_app/math.ex")
    end
  end
end
