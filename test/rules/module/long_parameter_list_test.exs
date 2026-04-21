defmodule Archdo.Rules.Module.LongParameterListTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.LongParameterList

  describe "analyze/3" do
    test "flags public function with 5 parameters as info" do
      code = ~S"""
      defmodule MyApp.Service do
        def create(a, b, c, d, e) do
          {a, b, c, d, e}
        end
      end
      """

      diags = assert_flagged(LongParameterList, code)
      assert length(diags) == 1
      assert hd(diags).rule_id == "6.43"
      assert hd(diags).severity == :info
    end

    test "flags public function with 7+ parameters as warning" do
      code = ~S"""
      defmodule MyApp.Service do
        def build(a, b, c, d, e, f, g) do
          {a, b, c, d, e, f, g}
        end
      end
      """

      diags = assert_flagged(LongParameterList, code)
      assert length(diags) == 1
      assert hd(diags).severity == :warning
    end

    test "allows public function with 4 parameters" do
      code = ~S"""
      defmodule MyApp.Service do
        def create(a, b, c, d) do
          {a, b, c, d}
        end
      end
      """

      assert_clean(LongParameterList, code)
    end

    test "skips generated functions like __changeset__" do
      code = ~S"""
      defmodule MyApp.Schema do
        def __changeset__(a, b, c, d, e) do
          {a, b, c, d, e}
        end
      end
      """

      assert_clean(LongParameterList, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        def create(a, b, c, d, e) do
          {a, b, c, d, e}
        end
      end
      """

      assert_clean(LongParameterList, code, file: "test/my_app/service_test.exs")
    end

    test "does not flag private functions" do
      code = ~S"""
      defmodule MyApp.Service do
        defp internal(a, b, c, d, e) do
          {a, b, c, d, e}
        end
      end
      """

      assert_clean(LongParameterList, code)
    end
  end
end
