defmodule Archdo.AST.MacroEdgesTest do
  use ExUnit.Case, async: true

  alias Archdo.AST.MacroEdges

  describe "extract/1 — pure AST → macro-emit edge map" do
    # M-fp-F1: a library macro `defmacro __using__(opts), do: quote do ... end`
    # may quote calls to sibling modules. Those calls materialize inside the
    # CONSUMER's compiled module after `use SomeMacroLib`. Static analysis
    # of the library in isolation cannot see the call edge in the library's
    # own BEAM. We reconstruct it by walking the macro body's AST and
    # treating every aliased + fully-qualified reference inside `quote`
    # blocks as a virtual edge from the defining module to the referenced
    # module.

    test "module with no macros returns empty map" do
      code = ~S"""
      defmodule MyApp.PlainModule do
        def regular_fn, do: :ok
      end
      """

      assert MacroEdges.extract(parse!(code)) == %{}
    end

    test "defmacro with quoted call to fully-qualified sibling extracts the edge" do
      # The Commanded shape — a library macro emits a call into the consumer.
      code = ~S"""
      defmodule Commanded.Commands.Router do
        defmacro __using__(_opts) do
          quote do
            def dispatch(cmd) do
              Commanded.Commands.Dispatcher.dispatch(cmd, [])
            end
          end
        end
      end
      """

      edges = MacroEdges.extract(parse!(code))
      assert Map.has_key?(edges, "Commanded.Commands.Router")
      router_edges = Map.fetch!(edges, "Commanded.Commands.Router")
      assert "Commanded.Commands.Dispatcher" in router_edges
    end

    test "defmacro with quoted alias inside quote extracts the aliased module" do
      # Commanded actually does `alias Commanded.Commands.Dispatcher` INSIDE
      # the quote block (the alias is emitted into the consumer). Pick this up.
      code = ~S"""
      defmodule Commanded.Commands.Router do
        defmacro __using__(_opts) do
          quote do
            defp do_dispatch(cmd, opts) do
              alias Commanded.Commands.Dispatcher
              alias Commanded.Commands.Dispatcher.Payload
              Dispatcher.dispatch(cmd, opts)
            end
          end
        end
      end
      """

      edges = MacroEdges.extract(parse!(code))
      router_edges = Map.fetch!(edges, "Commanded.Commands.Router")
      assert "Commanded.Commands.Dispatcher" in router_edges
      assert "Commanded.Commands.Dispatcher.Payload" in router_edges
    end

    test "defmacro without quote block produces no edges" do
      # `defmacro x, do: :ok` — no quote, no edges. Conservative.
      code = ~S"""
      defmodule MyApp.M do
        defmacro noop(_), do: :ok
      end
      """

      assert MacroEdges.extract(parse!(code)) == %{}
    end

    test "defmacrop is treated the same as defmacro" do
      code = ~S"""
      defmodule MyApp.M do
        defmacrop quoted_helper do
          quote do
            Sibling.Internal.go()
          end
        end
      end
      """

      edges = MacroEdges.extract(parse!(code))
      assert "Sibling.Internal" in Map.fetch!(edges, "MyApp.M")
    end

    test "multiple macros with overlapping references dedupe" do
      code = ~S"""
      defmodule MyApp.Router do
        defmacro a do
          quote do
            MyApp.Helper.run()
          end
        end

        defmacro b do
          quote do
            MyApp.Helper.run()
            MyApp.Other.go()
          end
        end
      end
      """

      edges = MacroEdges.extract(parse!(code))
      router_edges = Map.fetch!(edges, "MyApp.Router")
      # Helper appears in both macros — should appear once
      assert Enum.count(router_edges, &(&1 == "MyApp.Helper")) == 1
      assert "MyApp.Other" in router_edges
    end

    test "regular def/defp bodies are NOT scanned for edges" do
      # This rule fires only on macro bodies — regular function calls are
      # captured by the existing call-graph builder. We don't double-count.
      code = ~S"""
      defmodule MyApp.M do
        def regular do
          MyApp.NotAnEdge.fn_call()
        end
      end
      """

      assert MacroEdges.extract(parse!(code)) == %{}
    end

    test "non-module AST (e.g., bare top-level expression) returns empty map" do
      code = ~S"""
      :ok
      """

      assert MacroEdges.extract(parse!(code)) == %{}
    end

    test "macro body that quotes Erlang module call (`:foo.bar()`) is ignored" do
      # Erlang-style `:atom.fun()` does NOT name an Elixir module. Skip.
      code = ~S"""
      defmodule MyApp.M do
        defmacro x do
          quote do
            :gen_server.call(self(), :ping)
          end
        end
      end
      """

      assert MacroEdges.extract(parse!(code)) == %{}
    end
  end

  describe "extract_calls/1 — function-level edges from macro bodies" do
    # Companion to `extract/1`. While `extract/1` returns module-level
    # edges sufficient for 1.26's reachability closure, 6.24 needs
    # function-level precision: which `Mod.fn/arity` is actually called
    # by the macro-injected code? Extract `{module_str, fn_atom, arity}`
    # for every `Mod.fn(args)` inside `quote do ... end` blocks of
    # `defmacro` bodies.

    test "no defmacro returns empty list" do
      code = ~S"""
      defmodule Plain do
        def regular, do: :ok
      end
      """

      assert MacroEdges.extract_calls(parse!(code)) == []
    end

    test "captures the function name and arity of a quoted call" do
      code = ~S"""
      defmodule Commanded.Commands.Router do
        defmacro dispatch(_cmd) do
          quote do
            Commanded.Commands.Dispatcher.dispatch(unquote_splicing([]))
          end
        end
      end
      """

      calls = MacroEdges.extract_calls(parse!(code))
      assert {"Commanded.Commands.Dispatcher", :dispatch, 1} in calls
    end

    test "captures multiple distinct function-level calls" do
      code = ~S"""
      defmodule M do
        defmacro emit do
          quote do
            Sibling.do_a()
            Sibling.do_b(:x, :y)
            Other.run()
          end
        end
      end
      """

      calls = MacroEdges.extract_calls(parse!(code))
      assert {"Sibling", :do_a, 0} in calls
      assert {"Sibling", :do_b, 2} in calls
      assert {"Other", :run, 0} in calls
    end

    test "deduplicates same {mod, fn, arity}" do
      code = ~S"""
      defmodule M do
        defmacro a do
          quote do
            Helper.run()
          end
        end

        defmacro b do
          quote do
            Helper.run()
          end
        end
      end
      """

      calls = MacroEdges.extract_calls(parse!(code))
      assert Enum.count(calls, &(&1 == {"Helper", :run, 0})) == 1
    end

    test "ignores Erlang-style :atom.fun() calls" do
      code = ~S"""
      defmodule M do
        defmacro x do
          quote do
            :gen_server.call(self(), :ping)
          end
        end
      end
      """

      assert MacroEdges.extract_calls(parse!(code)) == []
    end

    test "ignores calls in regular def bodies (only defmacro)" do
      code = ~S"""
      defmodule M do
        def regular do
          Helper.run()
        end
      end
      """

      assert MacroEdges.extract_calls(parse!(code)) == []
    end
  end

  defp parse!(code), do: Code.string_to_quoted!(code)
end
