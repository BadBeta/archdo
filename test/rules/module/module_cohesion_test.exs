defmodule Archdo.Rules.Module.ModuleCohesionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ModuleCohesion

  test "flags module with too many public functions" do
    fns = Enum.map_join(1..22, "\n", fn i -> "  def func_#{i}, do: :ok" end)

    code = """
    defmodule MyApp.GodModule do
      @moduledoc false
    #{fns}
    end
    """

    diags = assert_flagged(ModuleCohesion, code)
    assert hd(diags).message =~ "22 public functions"
  end

  test "allows module with few public functions" do
    code = ~S"""
    defmodule MyApp.Simple do
      @moduledoc false
      def foo, do: :ok
      def bar, do: :ok
    end
    """

    assert_clean(ModuleCohesion, code)
  end

  test "subtracts delegates from count" do
    delegates =
      Enum.map_join(1..22, "\n", fn i -> "  defdelegate func_#{i}(x), to: MyApp.Impl" end)

    code = """
    defmodule MyApp.Facade do
      @moduledoc "Context facade"
    #{delegates}
    end
    """

    assert_clean(ModuleCohesion, code)
  end
end
