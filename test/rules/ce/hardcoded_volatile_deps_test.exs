defmodule Archdo.Rules.CE.HardcodedVolatileDepsTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.HardcodedVolatileDeps

  test "fires when a volatile module calls a volatile dep directly" do
    code = ~S"""
    defmodule MyApp.HttpAdapter do
      def fetch(url), do: Tesla.get(url)
    end
    """

    diags = assert_flagged(HardcodedVolatileDeps, code, file: "lib/my_app/http_adapter.ex")
    assert hd(diags).rule_id == "CE-1"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "Tesla"
  end

  test "does NOT fire when the module declares an @behaviour for the dep" do
    # The presence of @behaviour signals an explicit seam — Mox can
    # generate a test double; production wires the real adapter.
    code = ~S"""
    defmodule MyApp.HttpAdapter do
      @callback get(url :: String.t()) :: {:ok, map()} | {:error, term()}
      def get(url), do: Tesla.get(url)
    end
    """

    assert_clean(HardcodedVolatileDeps, code, file: "lib/my_app/http_adapter.ex")
  end

  test "does NOT fire when the dep is passed as a function argument (DI)" do
    code = ~S"""
    defmodule MyApp.HttpFetcher do
      def fetch(http_client, url), do: http_client.get(url)
    end
    """

    # No volatile call, so module isn't volatile-tagged either; rule
    # short-circuits.
    assert_clean(HardcodedVolatileDeps, code, file: "lib/my_app/http_fetcher.ex")
  end

  test "does NOT fire when the dep is bound via Application.compile_env" do
    code = ~S"""
    defmodule MyApp.HttpAdapter do
      @client Application.compile_env!(:my_app, :http_client)
      def fetch(url), do: @client.get(url)
    end
    """

    assert_clean(HardcodedVolatileDeps, code, file: "lib/my_app/http_adapter.ex")
  end

  test "does NOT fire on a stable module (CE-1 is volatile-only)" do
    code = ~S"""
    defmodule MyApp.Pure do
      def normalize(s), do: URI.parse(s)
    end
    """

    assert_clean(HardcodedVolatileDeps, code, file: "lib/my_app/pure.ex")
  end
end
