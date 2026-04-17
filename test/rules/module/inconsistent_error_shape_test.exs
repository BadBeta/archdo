defmodule Archdo.Rules.Module.InconsistentErrorShapeTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.InconsistentErrorShape

  describe "analyze/3" do
    test "flags module that mixes ok/error tuples with raises" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create_user(attrs) do
          {:ok, %{name: attrs.name}}
        end

        def get_user(id) do
          raise "not found"
        end
      end
      """

      diags = assert_flagged(InconsistentErrorShape, code)
      assert hd(diags).rule_id == "6.11"
    end

    test "allows module with consistent ok/error tuples" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create_user(attrs) do
          {:ok, %{name: attrs.name}}
        end

        def update_user(user, attrs) do
          {:ok, %{user | name: attrs.name}}
        end

        def delete_user(user) do
          {:error, :not_implemented}
        end
      end
      """

      assert_clean(InconsistentErrorShape, code)
    end

    test "allows module with single function" do
      code = ~S"""
      defmodule MyApp.Simple do
        def run(data) do
          {:ok, process(data)}
        end
      end
      """

      assert_clean(InconsistentErrorShape, code)
    end
  end
end
