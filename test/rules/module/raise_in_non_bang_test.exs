defmodule Archdo.Rules.Module.RaiseInNonBangTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.RaiseInNonBang

  describe "analyze/3" do
    test "flags non-bang function that raises" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          if input == "" do
            raise ArgumentError, "input cannot be empty"
          end

          do_parse(input)
        end
      end
      """

      diags = assert_flagged(RaiseInNonBang, code)
      diag = hd(diags)
      assert diag.rule_id == "6.10"
      assert diag.severity == :warning
    end

    test "allows bang function that raises" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse!(input) do
          if input == "" do
            raise ArgumentError, "input cannot be empty"
          end

          do_parse(input)
        end
      end
      """

      assert_clean(RaiseInNonBang, code)
    end

    test "allows non-bang function without raise" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          case do_parse(input) do
            {:ok, result} -> {:ok, result}
            {:error, reason} -> {:error, reason}
          end
        end
      end
      """

      assert_clean(RaiseInNonBang, code)
    end

    test "allows init/1 with raise (setup context)" do
      code = ~S"""
      defmodule MyApp.Worker do
        def init(opts) do
          unless Keyword.has_key?(opts, :name) do
            raise ArgumentError, "missing required :name option"
          end

          {:ok, opts}
        end
      end
      """

      assert_clean(RaiseInNonBang, code)
    end

    test "skips private functions" do
      code = ~S"""
      defmodule MyApp.Internal do
        defp validate(data) do
          raise "bad data"
        end
      end
      """

      assert_clean(RaiseInNonBang, code)
    end
  end
end
