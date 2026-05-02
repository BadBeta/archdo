defmodule Archdo.NamingTest do
  use ExUnit.Case, async: true

  alias Archdo.Naming

  describe "stem/1" do
    test "collapses created/create/creating to a common stem" do
      assert Naming.stem("create") == Naming.stem("created")
      assert Naming.stem("creating") == Naming.stem("create")
    end

    test "collapses singular/plural" do
      assert Naming.stem("user") == Naming.stem("users")
    end

    test "ies → y" do
      assert Naming.stem("entries") == "entry"
    end

    test "passes through stems that don't match any suffix" do
      assert Naming.stem("foo") == "foo"
    end
  end

  describe "bang?/1" do
    test "true for atom names ending in `!`" do
      assert Naming.bang?(:fetch!)
      assert Naming.bang?(:create_user!)
    end

    test "false for atom names not ending in `!`" do
      refute Naming.bang?(:fetch)
      refute Naming.bang?(:create_user)
      refute Naming.bang?(:foo)
    end

    test "false for non-atom inputs (defensive — function names from `def unquote(...)`)" do
      refute Naming.bang?({:unquote, [], [{:name, [], nil}]})
      refute Naming.bang?(nil)
      refute Naming.bang?("fetch!")
    end
  end
end
