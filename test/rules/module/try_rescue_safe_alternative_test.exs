defmodule Archdo.Rules.Module.TryRescueSafeAlternativeTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.TryRescueSafeAlternative

  test "fires on `try do String.to_integer(x) rescue _ -> :error end` (Integer.parse exists)" do
    code = ~S"""
    defmodule MyApp.Parse do
      def to_int(s) do
        try do
          {:ok, String.to_integer(s)}
        rescue
          _ -> :error
        end
      end
    end
    """

    diags = assert_flagged(TryRescueSafeAlternative, code)
    assert hd(diags).rule_id == "6.78"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "Integer.parse"
  end

  test "fires on `try do Map.fetch!(m, k) rescue _ end` (Map.fetch exists)" do
    code = ~S"""
    defmodule MyApp.Cfg do
      def get(map, key) do
        try do
          {:ok, Map.fetch!(map, key)}
        rescue
          KeyError -> :error
        end
      end
    end
    """

    diags = assert_flagged(TryRescueSafeAlternative, code)
    assert hd(diags).rule_id == "6.78"
    assert hd(diags).message =~ "Map.fetch"
  end

  test "does NOT fire on try/rescue without a known safe alternative inside" do
    code = ~S"""
    defmodule MyApp.External do
      def call(url) do
        try do
          ExternalService.fetch(url)
        rescue
          e -> {:error, e}
        end
      end
    end
    """

    assert_clean(TryRescueSafeAlternative, code)
  end
end
