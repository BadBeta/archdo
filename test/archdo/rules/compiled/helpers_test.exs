defmodule Archdo.Rules.Compiled.HelpersTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Compiled.Helpers

  describe "framework_function?/1" do
    test "true for the canonical framework-generated names" do
      for name <- [
            :__struct__,
            :__schema__,
            :__changeset__,
            :__impl__,
            :__protocol__,
            :__deriving__,
            :__using__,
            :__before_compile__,
            :__after_compile__,
            :behaviour_info
          ] do
        assert Helpers.framework_function?(name), "expected #{name}"
      end
    end

    test "false for ordinary function names" do
      refute Helpers.framework_function?(:my_fun)
      refute Helpers.framework_function?(:start_link)
    end
  end

  describe "generated_function?/1" do
    test "true for double-underscore names (Elixir internal)" do
      assert Helpers.generated_function?(:__struct__)
      assert Helpers.generated_function?(:__nonsense__)
    end

    test "true for MACRO-prefixed names" do
      assert Helpers.generated_function?(:"MACRO-foo")
    end

    test "false for ordinary names" do
      refute Helpers.generated_function?(:my_fun)
      refute Helpers.generated_function?(:do_thing)
    end
  end

  describe "percentage/2" do
    test "rounds to an integer 0..100" do
      assert Helpers.percentage(0, 100) == 0
      assert Helpers.percentage(50, 100) == 50
      assert Helpers.percentage(100, 100) == 100
      assert Helpers.percentage(1, 3) == 33
      assert Helpers.percentage(2, 3) == 67
    end
  end

  describe "application_entry_point?/1" do
    test "true for *.Application modules" do
      assert Helpers.application_entry_point?(MyApp.Application)
      assert Helpers.application_entry_point?(Some.Other.App.Application)
    end

    test "true for *.MixProject modules" do
      assert Helpers.application_entry_point?(MyApp.MixProject)
    end

    test "false for ordinary modules" do
      refute Helpers.application_entry_point?(MyApp.Accounts)
      refute Helpers.application_entry_point?(MyApp.Worker)
    end
  end
end
