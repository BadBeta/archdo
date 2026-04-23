defmodule Archdo.Rules.OTP.AtomInHotPathTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.AtomInHotPath

  describe "analyze/3" do
    test "flags String.to_atom inside handle_call" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer

        def handle_call({:lookup, key}, _from, state) do
          atom_key = String.to_atom(key)
          {:reply, Map.get(state, atom_key), state}
        end
      end
      """

      diags = assert_flagged(AtomInHotPath, code)
      diag = hd(diags)
      assert diag.severity == :warning
      assert diag.rule_id == "5.44"
      assert diag.context.hot_path =~ "GenServer"
    end

    test "flags String.to_atom inside handle_info" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer

        def handle_info({:process, key}, state) do
          atom_key = String.to_atom(key)
          {:noreply, Map.put(state, atom_key, true)}
        end
      end
      """

      diags = assert_flagged(AtomInHotPath, code)
      diag = hd(diags)
      assert diag.context.hot_path =~ "GenServer"
    end

    test "flags String.to_atom inside Enum.map" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(items) do
          Enum.map(items, fn item ->
            String.to_atom(item)
          end)
        end
      end
      """

      diags = assert_flagged(AtomInHotPath, code)
      diag = hd(diags)
      assert diag.context.hot_path == "loop body"
    end

    test "flags String.to_atom inside for comprehension" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(items) do
          for item <- items do
            String.to_atom(item)
          end
        end
      end
      """

      diags = assert_flagged(AtomInHotPath, code)
      diag = hd(diags)
      assert diag.context.hot_path == "loop body"
    end

    test "allows String.to_existing_atom in callbacks" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer

        def handle_call({:lookup, key}, _from, state) do
          atom_key = String.to_existing_atom(key)
          {:reply, Map.get(state, atom_key), state}
        end
      end
      """

      assert_clean(AtomInHotPath, code)
    end

    test "allows String.to_atom outside hot paths" do
      code = ~S"""
      defmodule MyApp.Config do
        def load(key) do
          String.to_atom(key)
        end
      end
      """

      assert_clean(AtomInHotPath, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "something" do
          Enum.map(["a", "b"], &String.to_atom/1)
        end
      end
      """

      assert_clean(AtomInHotPath, code, file: "test/worker_test.exs")
    end
  end
end
