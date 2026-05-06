defmodule Archdo.Rules.Module.SilentRescueTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.SilentRescue

  test "fires on `rescue _ -> nil` (silent swallow with no logging)" do
    code = ~S"""
    defmodule MyApp.Risky do
      def maybe(arg) do
        try do
          do_work(arg)
        rescue
          _ -> nil
        end
      end

      defp do_work(_), do: :ok
    end
    """

    diags = assert_flagged(SilentRescue, code)
    assert hd(diags).rule_id == "6.80"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "silently"
  end

  test "fires on `rescue _ -> :error`" do
    code = ~S"""
    defmodule MyApp.Risky do
      def maybe(arg) do
        try do
          do_work(arg)
        rescue
          _ -> :error
        end
      end

      defp do_work(_), do: :ok
    end
    """

    diags = assert_flagged(SilentRescue, code)
    assert hd(diags).rule_id == "6.80"
  end

  test "does NOT fire when the rescue clause logs OR re-raises" do
    code = ~S"""
    defmodule MyApp.Risky do
      require Logger

      def maybe(arg) do
        try do
          do_work(arg)
        rescue
          e ->
            Logger.error("operation failed: \#{Exception.message(e)}")
            :error
        end
      end

      defp do_work(_), do: :ok
    end
    """

    assert_clean(SilentRescue, code)
  end
end
