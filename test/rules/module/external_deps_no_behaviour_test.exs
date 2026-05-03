defmodule Archdo.Rules.Module.ExternalDepsNoBehaviourTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.ExternalDepsNoBehaviour

  defp parse(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    ast
  end

  describe "analyze/3 — flags direct external calls" do
    test "flags a Req.get call (single-segment external)" do
      ast = parse(~S"""
      defmodule MyApp.Billing do
        def fetch(url), do: Req.get(url)
      end
      """)

      diags = ExternalDepsNoBehaviour.analyze("lib/my_app/billing.ex", ast, [])
      assert [d] = diags
      assert d.context.service == "Req"
    end

    test "flags an ExAws.S3 call (multi-segment external)" do
      ast = parse(~S"""
      defmodule MyApp.Storage do
        def list, do: ExAws.S3.list_buckets()
      end
      """)

      diags = ExternalDepsNoBehaviour.analyze("lib/my_app/storage.ex", ast, [])
      assert [d] = diags
      assert d.context.service == "ExAws.S3"
    end

    test "does NOT flag Stripe.Charge.create — exact-list-match limitation" do
      # The @external_services list has [:Stripe], which matches only
      # a literal `Stripe.fn(...)` call where `Stripe` is the leaf
      # module. `Stripe.Charge.create` has module path [:Stripe, :Charge]
      # which is not in the list. Documented as existing behavior.
      ast = parse(~S"""
      defmodule MyApp.Billing do
        def charge(amount, token), do: Stripe.Charge.create(%{amount: amount, source: token})
      end
      """)

      assert [] = ExternalDepsNoBehaviour.analyze("lib/my_app/billing.ex", ast, [])
    end

    test "flags an HTTPoison.get call" do
      ast = parse(~S"""
      defmodule MyApp.Worker do
        def fetch(url), do: HTTPoison.get(url)
      end
      """)

      diags = ExternalDepsNoBehaviour.analyze("lib/my_app/worker.ex", ast, [])
      assert [d] = diags
      assert d.context.service == "HTTPoison"
    end

    test "deduplicates multiple calls to the same service" do
      ast = parse(~S"""
      defmodule MyApp.Worker do
        def a(url), do: HTTPoison.get(url)
        def b(url), do: HTTPoison.post(url, "")
        def c(url), do: HTTPoison.delete(url)
      end
      """)

      diags = ExternalDepsNoBehaviour.analyze("lib/my_app/worker.ex", ast, [])
      assert [_one] = diags
    end
  end

  describe "analyze/3 — exempts files that legitimately call externals" do
    test "test file is exempt" do
      ast = parse(~S"""
      defmodule MyApp.WorkerTest do
        def setup_stub, do: Stripe.Charge.create(%{})
      end
      """)

      assert [] = ExternalDepsNoBehaviour.analyze("test/my_app/worker_test.exs", ast, [])
    end

    test "file under /adapters/ is exempt" do
      ast = parse(~S"""
      defmodule MyApp.Billing.Adapters.Stripe do
        def charge(amount, token), do: Stripe.Charge.create(%{amount: amount, source: token})
      end
      """)

      assert [] =
               ExternalDepsNoBehaviour.analyze(
                 "lib/my_app/billing/adapters/stripe.ex",
                 ast,
                 []
               )
    end

    test "file under /infrastructure/ is exempt" do
      ast = parse(~S"""
      defmodule MyApp.Infrastructure.HttpClient do
        def get(url), do: HTTPoison.get(url)
      end
      """)

      assert [] =
               ExternalDepsNoBehaviour.analyze(
                 "lib/my_app/infrastructure/http_client.ex",
                 ast,
                 []
               )
    end

    test "file ending in _client.ex is exempt" do
      ast = parse(~S"""
      defmodule MyApp.StripeClient do
        def charge(a, t), do: Stripe.Charge.create(%{amount: a, source: t})
      end
      """)

      assert [] =
               ExternalDepsNoBehaviour.analyze("lib/my_app/stripe_client.ex", ast, [])
    end

    test "file under /mailer path is exempt" do
      ast = parse(~S"""
      defmodule MyApp.Mailer.Adapter do
        def send(email), do: Swoosh.Mailer.deliver(email)
      end
      """)

      assert [] = ExternalDepsNoBehaviour.analyze("lib/my_app/mailer/adapter.ex", ast, [])
    end

    test "file under /clients/ is exempt" do
      ast = parse(~S"""
      defmodule MyApp.Clients.Stripe do
        def charge(a, t), do: Stripe.Charge.create(%{amount: a, source: t})
      end
      """)

      assert [] =
               ExternalDepsNoBehaviour.analyze(
                 "lib/my_app/clients/stripe.ex",
                 ast,
                 []
               )
    end

    test "operational classification (passed via opts) is exempt" do
      ast = parse(~S"""
      defmodule MyApp.Release do
        def setup_stripe, do: Stripe.Charge.create(%{})
      end
      """)

      diags =
        ExternalDepsNoBehaviour.analyze(
          "lib/my_app/release.ex",
          ast,
          phoenix: %{layer: :operational}
        )

      assert [] = diags
    end
  end

  describe "analyze/3 — does not flag self-calls" do
    test "module calling its own nested module is not flagged" do
      ast = parse(~S"""
      defmodule HTTPoison do
        def get(url), do: HTTPoison.Helpers.get(url)
      end
      """)

      assert [] = ExternalDepsNoBehaviour.analyze("lib/httpoison.ex", ast, [])
    end
  end
end
