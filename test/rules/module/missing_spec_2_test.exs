defmodule Archdo.Rules.Module.MissingSpecTest2 do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.MissingSpec

  describe "analyze/3" do
    test "flags public function without @spec" do
      code = ~S"""
      defmodule MyApp.Accounts do
        @moduledoc "User management"

        def create_user(attrs) do
          {:ok, attrs}
        end
      end
      """

      diags = assert_flagged(MissingSpec, code)
      assert hd(diags).rule_id == "2.2"
    end

    test "allows public function with @spec" do
      code = ~S"""
      defmodule MyApp.Accounts do
        @moduledoc "User management"

        @spec create_user(map()) :: {:ok, map()}
        def create_user(attrs) do
          {:ok, attrs}
        end
      end
      """

      assert_clean(MissingSpec, code)
    end

    test "skips modules with @moduledoc false" do
      code = ~S"""
      defmodule MyApp.Internal do
        @moduledoc false

        def helper(x), do: x
      end
      """

      assert_clean(MissingSpec, code)
    end
  end
end
