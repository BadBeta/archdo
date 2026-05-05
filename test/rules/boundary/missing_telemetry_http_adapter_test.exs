defmodule Archdo.Rules.Boundary.MissingTelemetryHttpAdapterTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Boundary.MissingTelemetryHttpAdapter

  test "fires on a module with 5+ HTTP calls and no telemetry" do
    code = ~S"""
    defmodule MyApp.Stripe do
      def get_charge(id), do: Req.get("/charges/#{id}")
      def list_charges, do: Req.get("/charges")
      def create_charge(attrs), do: Req.post("/charges", json: attrs)
      def update_charge(id, attrs), do: Req.put("/charges/#{id}", json: attrs)
      def delete_charge(id), do: Req.delete("/charges/#{id}")
    end
    """

    diags = assert_flagged(MissingTelemetryHttpAdapter, code, file: "lib/my_app/stripe.ex")
    assert hd(diags).rule_id == "4.22"
    assert hd(diags).severity == :info
  end

  test "does NOT fire when an HTTP-heavy module emits telemetry" do
    code = ~S"""
    defmodule MyApp.Stripe do
      def get_charge(id) do
        :telemetry.span([:stripe, :get_charge], %{id: id}, fn ->
          {Req.get("/charges/#{id}"), %{}}
        end)
      end

      def list_charges, do: Req.get("/charges")
      def create_charge(a), do: Req.post("/charges", json: a)
      def update_charge(id, a), do: Req.put("/charges/#{id}", json: a)
      def delete_charge(id), do: Req.delete("/charges/#{id}")
    end
    """

    assert_clean(MissingTelemetryHttpAdapter, code, file: "lib/my_app/stripe.ex")
  end

  test "does NOT fire on a module with fewer than 5 HTTP calls" do
    code = ~S"""
    defmodule MyApp.SmallClient do
      def fetch, do: Req.get("/")
      def push(d), do: Req.post("/", json: d)
    end
    """

    assert_clean(MissingTelemetryHttpAdapter, code, file: "lib/my_app/small_client.ex")
  end
end
