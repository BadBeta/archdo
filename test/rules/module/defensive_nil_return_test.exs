defmodule Archdo.Rules.Module.DefensiveNilReturnTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.DefensiveNilReturn

  describe "catch-all returning nil" do
    test "flags _ -> nil with 3+ clauses" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          case input do
            {:ok, val} -> val
            {:error, reason} -> {:error, reason}
            _ -> nil
          end
        end
      end
      """

      diagnostics = assert_flagged(DefensiveNilReturn, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.39"
      assert diag.severity == :info
      assert diag.message =~ "catch-all clause"
      assert diag.message =~ "nil"
    end

    test "flags bare variable -> nil with 3+ clauses" do
      code = ~S"""
      defmodule MyApp.Decoder do
        def decode(msg) do
          case msg do
            %{type: :text, body: body} -> {:text, body}
            %{type: :binary, data: data} -> {:binary, data}
            other -> nil
          end
        end
      end
      """

      diagnostics = assert_flagged(DefensiveNilReturn, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.39"
    end

    test "flags nested case with defensive nil" do
      code = ~S"""
      defmodule MyApp.Handler do
        def handle(event) do
          result = case event do
            :start -> do_start()
            :stop -> do_stop()
            :pause -> do_pause()
            _ -> nil
          end
          result
        end

        defp do_start, do: :started
        defp do_stop, do: :stopped
        defp do_pause, do: :paused
      end
      """

      diagnostics = assert_flagged(DefensiveNilReturn, code)
      assert [diag] = diagnostics
    end
  end

  describe "clean patterns" do
    test "does not flag _ -> :error (meaningful error handling)" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          case input do
            {:ok, val} -> val
            {:error, reason} -> {:error, reason}
            _ -> :error
          end
        end
      end
      """

      assert_clean(DefensiveNilReturn, code)
    end

    test "does not flag _ -> {:error, _} (tagged error)" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          case input do
            {:ok, val} -> val
            {:error, reason} -> {:error, reason}
            _ -> {:error, :unknown}
          end
        end
      end
      """

      assert_clean(DefensiveNilReturn, code)
    end

    test "does not flag two-clause case (catch-all IS the logic)" do
      code = ~S"""
      defmodule MyApp.Checker do
        def check(val) do
          case val do
            :expected -> :ok
            _ -> nil
          end
        end
      end
      """

      assert_clean(DefensiveNilReturn, code)
    end

    test "does not flag case without catch-all" do
      code = ~S"""
      defmodule MyApp.Handler do
        def handle(msg) do
          case msg do
            :ping -> :pong
            :hello -> :world
            :bye -> :farewell
          end
        end
      end
      """

      assert_clean(DefensiveNilReturn, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.ParserTest do
        def helper(input) do
          case input do
            {:ok, val} -> val
            {:error, _} -> :err
            _ -> nil
          end
        end
      end
      """

      assert_clean(DefensiveNilReturn, code, file: "test/parser_test.exs")
    end
  end
end
