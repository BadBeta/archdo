defmodule Archdo.Rules.Module.KeywordValidateOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.KeywordValidateOpportunity

  test "fires on 3+ Keyword.get(opts, :k, default) calls on same opts var" do
    code = ~S"""
    defmodule MyApp.Worker do
      def start_link(opts) do
        timeout = Keyword.get(opts, :timeout, 5_000)
        max_retries = Keyword.get(opts, :max_retries, 3)
        name = Keyword.get(opts, :name, __MODULE__)
        do_start(timeout, max_retries, name)
      end

      defp do_start(_, _, _), do: :ok
    end
    """

    diags = assert_flagged(KeywordValidateOpportunity, code)
    assert hd(diags).rule_id == "6.83"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "Keyword.validate"
  end

  test "does NOT fire on Keyword.validate!/2 (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Worker do
      def start_link(opts) do
        opts = Keyword.validate!(opts, timeout: 5_000, max_retries: 3, name: __MODULE__)
        do_start(opts)
      end

      defp do_start(_), do: :ok
    end
    """

    assert_clean(KeywordValidateOpportunity, code)
  end

  test "does NOT fire on fewer than 3 Keyword.get calls" do
    code = ~S"""
    defmodule MyApp.Small do
      def go(opts) do
        timeout = Keyword.get(opts, :timeout, 5_000)
        do_go(timeout)
      end

      defp do_go(_), do: :ok
    end
    """

    assert_clean(KeywordValidateOpportunity, code)
  end
end
