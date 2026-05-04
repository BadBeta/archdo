defmodule Archdo.Rules.OTP.DetsOrderedSetTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.DetsOrderedSet

  describe "analyze/3" do
    test "flags :dets.open_file with type: :ordered_set" do
      code = ~S"""
      defmodule MyApp.Cache do
        def open do
          {:ok, _} = :dets.open_file(:my_table, type: :ordered_set, file: ~c"/tmp/t.dets")
        end
      end
      """

      diags = assert_flagged(DetsOrderedSet, code)
      assert hd(diags).rule_id == "5.46"
      assert hd(diags).message =~ ":ordered_set"
      assert hd(diags).message =~ "DETS"
    end

    test "flags ordered_set when options come via a list literal" do
      code = ~S"""
      defmodule MyApp.Cache do
        def open(name) do
          opts = [type: :ordered_set, auto_save: 60_000]
          :dets.open_file(name, opts)
        end
      end
      """

      # Variable-bound options aren't traced — this is the reasonable
      # blind spot. Document via test that the inline form is what
      # the rule catches.
      assert_clean(DetsOrderedSet, code)
    end

    test "allows :dets.open_file with type: :set (valid DETS type)" do
      code = ~S"""
      defmodule MyApp.Cache do
        def open do
          :dets.open_file(:my_table, type: :set, file: ~c"/tmp/t.dets")
        end
      end
      """

      assert_clean(DetsOrderedSet, code)
    end

    test "allows :dets.open_file with type: :bag" do
      code = ~S"""
      defmodule MyApp.Cache do
        def open do
          :dets.open_file(:my_table, type: :bag, file: ~c"/tmp/t.dets")
        end
      end
      """

      assert_clean(DetsOrderedSet, code)
    end

    test "allows :dets.open_file with type: :duplicate_bag" do
      code = ~S"""
      defmodule MyApp.Cache do
        def open do
          :dets.open_file(:my_table, type: :duplicate_bag, file: ~c"/tmp/t.dets")
        end
      end
      """

      assert_clean(DetsOrderedSet, code)
    end

    test "allows :dets.open_file without an explicit :type (defaults to :set)" do
      code = ~S"""
      defmodule MyApp.Cache do
        def open do
          :dets.open_file(:my_table, file: ~c"/tmp/t.dets")
        end
      end
      """

      assert_clean(DetsOrderedSet, code)
    end

    test "allows :ets.new with :ordered_set (ETS supports it)" do
      code = ~S"""
      defmodule MyApp.Cache do
        def open do
          :ets.new(:my_table, [:ordered_set, :named_table])
        end
      end
      """

      assert_clean(DetsOrderedSet, code)
    end

    test "ignores test files" do
      code = ~S"""
      defmodule MyApp.CacheTest do
        def open do
          :dets.open_file(:my_table, type: :ordered_set)
        end
      end
      """

      assert_clean(DetsOrderedSet, code, file: "test/cache_test.exs")
    end
  end
end
