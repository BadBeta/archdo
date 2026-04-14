defmodule Archdo.Rules.OTP.ProcessDictionaryTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.ProcessDictionary

  test "flags Process.put in production code" do
    code = ~S"""
    defmodule MyApp.Worker do
      def store_context(key, value) do
        Process.put(key, value)
      end
    end
    """

    assert_flagged(ProcessDictionary, code)
  end

  test "flags Process.get in production code" do
    code = ~S"""
    defmodule MyApp.Worker do
      def fetch_context(key) do
        Process.get(key)
      end
    end
    """

    assert_flagged(ProcessDictionary, code)
  end

  test "allows Process.put in test files" do
    code = ~S"""
    defmodule MyApp.WorkerTest do
      def setup do
        Process.put(:test_key, :test_value)
      end
    end
    """

    assert_clean(ProcessDictionary, code, file: "test/worker_test.exs")
  end

  test "allows code without process dictionary access" do
    code = ~S"""
    defmodule MyApp.Worker do
      def compute(x), do: x * 2
    end
    """

    assert_clean(ProcessDictionary, code)
  end
end
