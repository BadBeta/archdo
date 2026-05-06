defmodule Archdo.Rules.Module.PipeSubjectPositionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.PipeSubjectPosition

  describe "subject-position violations" do
    test "flags public fn with opts-first, data-last" do
      code = ~S"""
      defmodule MyApp.Transform do
        def apply(opts, data) do
          do_apply(opts, data)
        end

        defp do_apply(_, d), do: d
      end
      """

      [diag] = assert_flagged(PipeSubjectPosition, code)
      assert diag.rule_id == "6.97"
      assert diag.severity == :info
      assert diag.message =~ "apply/2"
    end

    test "flags public fn with options-first, list-last" do
      code = ~S"""
      defmodule MyApp.Lib do
        def process(options, list) do
          Enum.map(list, fn x -> x + options[:offset] end)
        end
      end
      """

      [diag] = assert_flagged(PipeSubjectPosition, code)
      assert diag.message =~ "process/2"
    end

    test "flags public fn with config-first, value-last" do
      code = ~S"""
      defmodule MyApp.Encoder do
        def encode(config, value) do
          encode_with(config, value)
        end

        defp encode_with(_, v), do: v
      end
      """

      [diag] = assert_flagged(PipeSubjectPosition, code)
      assert diag.message =~ "encode/2"
    end

    test "flags fn with opts-first, struct-destructure-last" do
      code = ~S"""
      defmodule MyApp.User do
        def greet(opts, %User{name: name}) do
          name <> opts[:suffix]
        end
      end
      """

      [diag] = assert_flagged(PipeSubjectPosition, code)
      assert diag.message =~ "greet/2"
    end
  end

  describe "clean code" do
    test "does not flag fn with subject-first, opts-last" do
      code = ~S"""
      defmodule MyApp.Transform do
        def apply(data, opts) do
          do_apply(data, opts)
        end

        defp apply(_, _), do: :ok
      end
      """

      assert_clean(PipeSubjectPosition, code)
    end

    test "does not flag single-arg fn" do
      code = ~S"""
      defmodule MyApp.Simple do
        def transform(data), do: data
      end
      """

      assert_clean(PipeSubjectPosition, code)
    end

    test "does not flag private fn" do
      code = ~S"""
      defmodule MyApp.Internal do
        def run(data, opts), do: do_run(opts, data)
        defp do_run(opts, data), do: data
      end
      """

      assert_clean(PipeSubjectPosition, code)
    end

    test "does not flag fn where first-arg name does not suggest opts" do
      code = ~S"""
      defmodule MyApp.Service do
        def transfer(source, target, amount) do
          {source, target, amount}
        end
      end
      """

      assert_clean(PipeSubjectPosition, code)
    end

    test "does not flag fn where last-arg name does not suggest subject" do
      code = ~S"""
      defmodule MyApp.Logger do
        def configure(opts, level) do
          {opts, level}
        end
      end
      """

      assert_clean(PipeSubjectPosition, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.UserTest do
        def helper(opts, data), do: {opts, data}
      end
      """

      assert_clean(PipeSubjectPosition, code, file: "test/user_test.exs")
    end

    test "does not flag fn taking 3+ args (signature complexity moves it out of pipeline territory)" do
      code = ~S"""
      defmodule MyApp.Service do
        def call(opts, ref, data) do
          {opts, ref, data}
        end
      end
      """

      assert_clean(PipeSubjectPosition, code)
    end
  end

  describe "edge cases" do
    test "flags fn with default-value-form first arg" do
      code = ~S"""
      defmodule MyApp.Lib do
        def run(opts \\ [], data) do
          {opts, data}
        end
      end
      """

      [diag] = assert_flagged(PipeSubjectPosition, code)
      assert diag.message =~ "run/2"
    end
  end
end
