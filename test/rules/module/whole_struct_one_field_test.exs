defmodule Archdo.Rules.Module.WholeStructOneFieldTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.WholeStructOneField

  test "fires on `def f(%User{} = u), do: u.id` — only one field accessed" do
    code = ~S"""
    defmodule MyApp.Get do
      def user_id(%User{} = user), do: user.id
    end
    """

    diags = assert_flagged(WholeStructOneField, code)
    assert hd(diags).rule_id == "6.76"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "destructure"
  end

  test "does NOT fire on `def f(%User{id: id}), do: id` (already destructured)" do
    code = ~S"""
    defmodule MyApp.Get do
      def user_id(%User{id: id}), do: id
    end
    """

    assert_clean(WholeStructOneField, code)
  end

  test "does NOT fire when multiple fields are accessed" do
    code = ~S"""
    defmodule MyApp.Format do
      def display(%User{} = user), do: "\#{user.name} <\#{user.email}>"
    end
    """

    assert_clean(WholeStructOneField, code)
  end
end
