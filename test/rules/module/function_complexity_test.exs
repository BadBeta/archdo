defmodule Archdo.Rules.Module.FunctionComplexityTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.FunctionComplexity

  test "flags public function with arity > 5" do
    code = ~S"""
    defmodule MyApp.Complex do
      @moduledoc "Public module"
      def too_many(a, b, c, d, e, f) do
        {a, b, c, d, e, f}
      end
    end
    """

    diags = assert_flagged(FunctionComplexity, code)
    assert Enum.any?(diags, &(&1.title == "High function arity"))
  end

  test "allows function with arity <= 5" do
    code = ~S"""
    defmodule MyApp.Simple do
      @moduledoc false
      def ok(a, b, c) do
        {a, b, c}
      end
    end
    """

    assert_clean(FunctionComplexity, code)
  end

  test "flags high cyclomatic complexity" do
    # Build a function with many branches
    branches = Enum.map_join(1..12, "\n", fn i ->
      "      :val_#{i} -> :result_#{i}"
    end)

    code = """
    defmodule MyApp.Complex do
      @moduledoc false
      def complex_fn(x) do
        case x do
    #{branches}
        end
      end
    end
    """

    diags = assert_flagged(FunctionComplexity, code)
    assert Enum.any?(diags, &(&1.message =~ "cyclomatic complexity"))
  end
end
