defmodule Archdo.Rules.CE.MixedModuleSplitTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.MixedModuleSplit

  test "fires on a mixed-volatility module" do
    code = ~S"""
    defmodule MyApp.Mixed do
      def a, do: Tesla.get("/a")
      def b, do: URI.parse("/b")
      def c, do: URI.parse("/c")
      def d, do: URI.parse("/d")
      def e, do: URI.parse("/e")
    end
    """

    diags = assert_flagged(MixedModuleSplit, code, file: "lib/my_app/mixed.ex")
    assert hd(diags).rule_id == "CE-4"
    assert hd(diags).severity == :warning
  end

  test "does NOT fire on a stable module" do
    code = ~S"""
    defmodule MyApp.Pure do
      def normalize(s), do: URI.parse(s)
    end
    """

    assert_clean(MixedModuleSplit, code, file: "lib/my_app/pure.ex")
  end

  test "does NOT fire on a fully-volatile module" do
    code = ~S"""
    defmodule MyApp.Adapter do
      def fetch(url), do: Tesla.get(url)
      def post(url, body), do: Tesla.post(url, body)
    end
    """

    assert_clean(MixedModuleSplit, code, file: "lib/my_app/adapter.ex")
  end
end
