defmodule Archdo.Rules.Module.StreamOverEnumOpportunityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.StreamOverEnumOpportunity

  describe "Stream.* opportunity" do
    test "flags File.stream! piped through 3+ Enum.* calls" do
      code = ~S"""
      defmodule MyApp.LogProcessor do
        def count_errors(path) do
          path
          |> File.stream!()
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.contains?(&1, "ERROR"))
          |> Enum.count()
        end
      end
      """

      [diag] = assert_flagged(StreamOverEnumOpportunity, code)
      assert diag.rule_id == "6.99"
      assert diag.severity == :info
      assert diag.message =~ "Stream"
    end

    test "flags Repo.stream! piped through 3+ Enum.* calls" do
      code = ~S"""
      defmodule MyApp.UserExporter do
        def export do
          MyApp.User
          |> MyApp.Repo.stream()
          |> Enum.map(&serialize/1)
          |> Enum.reject(&banned?/1)
          |> Enum.into(%{})
        end

        defp serialize(u), do: u
        defp banned?(_), do: false
      end
      """

      [diag] = assert_flagged(StreamOverEnumOpportunity, code)
      assert diag.message =~ "Stream"
    end

    test "flags Stream.resource piped through 3+ Enum.* calls" do
      code = ~S"""
      defmodule MyApp.Producer do
        def consume do
          Stream.resource(
            fn -> 1 end,
            fn s -> {[s], s + 1} end,
            fn _ -> :ok end
          )
          |> Enum.map(&(&1 * 2))
          |> Enum.take(100)
          |> Enum.sum()
        end
      end
      """

      [diag] = assert_flagged(StreamOverEnumOpportunity, code)
      assert diag.message =~ "Stream"
    end
  end

  describe "clean code" do
    test "does not flag File.stream! piped through Stream.* calls" do
      code = ~S"""
      defmodule MyApp.LogProcessor do
        def count_errors(path) do
          path
          |> File.stream!()
          |> Stream.map(&String.trim/1)
          |> Stream.filter(&String.contains?(&1, "ERROR"))
          |> Enum.count()
        end
      end
      """

      assert_clean(StreamOverEnumOpportunity, code)
    end

    test "does not flag File.stream! with only 2 Enum steps" do
      code = ~S"""
      defmodule MyApp.LogProcessor do
        def errors(path) do
          path
          |> File.stream!()
          |> Enum.map(&String.trim/1)
          |> Enum.count()
        end
      end
      """

      assert_clean(StreamOverEnumOpportunity, code)
    end

    test "does not flag Enum chain whose source isn't streamy" do
      code = ~S"""
      defmodule MyApp.Pipeline do
        def run(items) do
          items
          |> Enum.map(&(&1 + 1))
          |> Enum.filter(&(&1 > 0))
          |> Enum.sum()
        end
      end
      """

      assert_clean(StreamOverEnumOpportunity, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.LogTest do
        def helper(p) do
          p
          |> File.stream!()
          |> Enum.map(& &1)
          |> Enum.filter(& &1)
          |> Enum.count()
        end
      end
      """

      assert_clean(StreamOverEnumOpportunity, code, file: "test/log_test.exs")
    end
  end
end
