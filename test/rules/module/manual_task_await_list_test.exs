defmodule Archdo.Rules.Module.ManualTaskAwaitListTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ManualTaskAwaitList

  test "fires on `Enum.map(coll, &Task.async/1) |> Enum.map(&Task.await/1)`" do
    code = ~S"""
    defmodule MyApp.Parallel do
      def fetch_all(urls) do
        urls
        |> Enum.map(&Task.async(fn -> fetch(&1) end))
        |> Enum.map(&Task.await/1)
      end

      defp fetch(_), do: :ok
    end
    """

    diags = assert_flagged(ManualTaskAwaitList, code)
    assert hd(diags).rule_id == "5.64"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "async_stream"
  end

  test "does NOT fire on Task.async_stream (already idiomatic)" do
    code = ~S"""
    defmodule MyApp.Parallel do
      def fetch_all(urls) do
        urls
        |> Task.async_stream(&fetch/1, timeout: 10_000)
        |> Enum.map(fn {:ok, r} -> r end)
      end

      defp fetch(_), do: :ok
    end
    """

    assert_clean(ManualTaskAwaitList, code)
  end

  test "does NOT fire on a single Task.async without the await pair" do
    code = ~S"""
    defmodule MyApp.Single do
      def go do
        task = Task.async(fn -> work() end)
        Task.await(task)
      end

      defp work, do: :ok
    end
    """

    assert_clean(ManualTaskAwaitList, code)
  end
end
