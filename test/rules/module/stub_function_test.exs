defmodule Archdo.Rules.Module.StubFunctionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.StubFunction

  describe "raise 'not implemented'" do
    test "flags raise with 'not implemented' message" do
      code = ~S"""
      defmodule MyApp.Payments do
        def charge(amount, token) do
          raise "not implemented"
        end
      end
      """

      diagnostics = assert_flagged(StubFunction, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.29"
      assert diag.message =~ "raises \"not implemented\""
    end

    test "flags raise with 'TODO' message" do
      code = ~S"""
      defmodule MyApp.Notifier do
        def send_email(user, template) do
          raise "TODO: implement email sending"
        end
      end
      """

      [diag] = assert_flagged(StubFunction, code)
      assert diag.message =~ "raises a TODO message"
    end

    test "flags raise with 'not yet implemented'" do
      code = ~S"""
      defmodule MyApp.Search do
        def query(term) do
          raise "not yet implemented"
        end
      end
      """

      [diag] = assert_flagged(StubFunction, code)
      assert diag.message =~ "not yet implemented"
    end
  end

  describe "IO.warn stubs" do
    test "flags IO.warn with not implemented" do
      code = ~S"""
      defmodule MyApp.Export do
        def to_csv(data) do
          IO.warn("not implemented")
        end
      end
      """

      [diag] = assert_flagged(StubFunction, code)
      assert diag.context.stub_type == :io_not_implemented
    end
  end

  describe "clean code" do
    test "does not flag real raise in guard/validation" do
      code = ~S"""
      defmodule MyApp.Validator do
        def validate!(data) do
          raise ArgumentError, "invalid data format"
        end
      end
      """

      assert_clean(StubFunction, code)
    end

    test "does not flag normal functions" do
      code = ~S"""
      defmodule MyApp.Math do
        def add(a, b), do: a + b
        def multiply(a, b), do: a * b
      end
      """

      assert_clean(StubFunction, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.PaymentsTest do
        def helper do
          raise "not implemented"
        end
      end
      """

      assert_clean(StubFunction, code, file: "test/payments_test.exs")
    end

    test "does not flag ok/error return patterns" do
      code = ~S"""
      defmodule MyApp.Service do
        def call(args) do
          {:ok, process(args)}
        end

        defp process(args), do: args
      end
      """

      assert_clean(StubFunction, code)
    end
  end

  describe "return value stubs" do
    test "flags :not_implemented atom return" do
      code = ~S"""
      defmodule MyApp.Legacy do
        def old_method(data) do
          :not_implemented
        end
      end
      """

      [diag] = assert_flagged(StubFunction, code)
      assert diag.context.stub_type == :atom_not_implemented
    end
  end
end
