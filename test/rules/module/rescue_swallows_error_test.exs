defmodule Archdo.Rules.Module.RescueSwallowsErrorTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.RescueSwallowsError

  describe "analyze/3" do
    test "flags rescue _ -> nil (returns default, swallows error)" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          do_parse(input)
        rescue
          _ -> nil
        end
      end
      """

      diags = assert_flagged(RescueSwallowsError, code)
      diag = hd(diags)
      assert diag.rule_id == "6.9"
      assert diag.severity == :warning
      assert diag.context.kind == :returns_default
    end

    test "flags rescue _ -> [] (returns empty list)" do
      code = ~S"""
      defmodule MyApp.Loader do
        def load_items do
          fetch_from_api()
        rescue
          _ -> []
        end
      end
      """

      diags = assert_flagged(RescueSwallowsError, code)
      assert hd(diags).context.kind in [:returns_default, :returns_empty]
    end

    test "flags rescue that discards error without logging" do
      code = ~S"""
      defmodule MyApp.Worker do
        def process(data) do
          transform(data)
        rescue
          _e -> :ignored
        end
      end
      """

      assert_flagged(RescueSwallowsError, code)
    end

    test "allows rescue that logs the error" do
      code = ~S"""
      defmodule MyApp.Worker do
        def process(data) do
          transform(data)
        rescue
          e ->
            Logger.warning("Failed: \#{inspect(e)}")
            :error
        end
      end
      """

      assert_clean(RescueSwallowsError, code)
    end

    test "allows rescue that returns {:error, reason}" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          {:ok, do_parse(input)}
        rescue
          e -> {:error, Exception.message(e)}
        end
      end
      """

      assert_clean(RescueSwallowsError, code)
    end

    test "allows rescue with reraise" do
      code = ~S"""
      defmodule MyApp.Boundary do
        def call(args) do
          external_service(args)
        rescue
          e ->
            reraise e, __STACKTRACE__
        end
      end
      """

      assert_clean(RescueSwallowsError, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.ParserTest do
        def test_parse do
          parse("bad")
        rescue
          _ -> nil
        end
      end
      """

      diags = analyze(RescueSwallowsError, code, file: "test/parser_test.exs")
      assert diags == []
    end
  end
end
