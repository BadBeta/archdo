defmodule Archdo.Rules.Module.CircuitBreakerInContextModuleTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.CircuitBreakerInContextModule

  describe "analyze/3" do
    test "flags Fuse calls in a top-level context module" do
      code = ~S"""
      defmodule MyApp.Billing do
        def charge(card, amount) do
          case :fuse.ask(:stripe_breaker, :sync) do
            :ok -> Stripe.charge(card, amount)
            :blown -> {:error, :unavailable}
          end
        end
      end
      """

      diags =
        assert_flagged(CircuitBreakerInContextModule, code,
          file: "lib/my_app/billing.ex"
        )

      assert hd(diags).rule_id == "1.36"
    end

    test "flags ExBreaker.run in a context module" do
      code = ~S"""
      defmodule MyApp.Billing do
        def charge(card, amount) do
          ExBreaker.run("stripe", fn -> Stripe.charge(card, amount) end)
        end
      end
      """

      assert_flagged(CircuitBreakerInContextModule, code, file: "lib/my_app/billing.ex")
    end

    test "ignores Fuse calls in adapter modules" do
      code = ~S"""
      defmodule MyApp.Billing.StripeAdapter do
        def charge(card, amount) do
          case :fuse.ask(:stripe_breaker, :sync) do
            :ok -> Stripe.charge(card, amount)
            :blown -> {:error, :unavailable}
          end
        end
      end
      """

      assert_clean(CircuitBreakerInContextModule, code,
        file: "lib/my_app/billing/stripe_adapter.ex"
      )
    end

    test "ignores Fuse calls in client modules" do
      code = ~S"""
      defmodule MyApp.Billing.StripeClient do
        def charge(card, amount) do
          :fuse.ask(:stripe, :sync)
        end
      end
      """

      assert_clean(CircuitBreakerInContextModule, code,
        file: "lib/my_app/billing/stripe_client.ex"
      )
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.BillingTest do
        def setup do
          :fuse.install(:test, {{:standard, 1, 1}, {:reset, 1}})
        end
      end
      """

      assert_clean(CircuitBreakerInContextModule, code, file: "test/billing_test.exs")
    end

    test "ignores modules without circuit breaker calls" do
      code = ~S"""
      defmodule MyApp.Billing do
        def charge(card, amount), do: Stripe.charge(card, amount)
      end
      """

      assert_clean(CircuitBreakerInContextModule, code, file: "lib/my_app/billing.ex")
    end
  end
end
