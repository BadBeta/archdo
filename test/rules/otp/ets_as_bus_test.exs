defmodule Archdo.Rules.OTP.EtsAsBusTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.EtsAsBus

  test "flags ETS insert + delete + polling pattern" do
    code = ~S"""
    defmodule MyApp.MessageQueue do
      def enqueue(table, msg) do
        :ets.insert(table, {System.monotonic_time(), msg})
      end

      def dequeue(table) do
        key = :ets.first(table)
        [{^key, msg}] = :ets.lookup(table, key)
        :ets.delete(table, key)
        msg
      end

      def poll(table) do
        case :ets.first(table) do
          :"$end_of_table" ->
            Process.sleep(100)
            poll(table)

          key ->
            :ets.next(table, key)
        end
      end
    end
    """

    assert_flagged(EtsAsBus, code)
  end

  test "allows ETS insert without polling" do
    code = ~S"""
    defmodule MyApp.Cache do
      def put(table, key, value) do
        :ets.insert(table, {key, value})
      end

      def get(table, key) do
        case :ets.lookup(table, key) do
          [{^key, value}] -> {:ok, value}
          [] -> :error
        end
      end
    end
    """

    assert_clean(EtsAsBus, code)
  end
end
