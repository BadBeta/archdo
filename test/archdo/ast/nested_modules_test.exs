defmodule Archdo.AST.NestedModulesTest do
  use ExUnit.Case, async: true

  alias Archdo.AST.NestedModules

  describe "extract/1 — pure AST → parent→nested edges" do
    # Lexical containment: a nested `defmodule X do; ...; end` inside a
    # parent module is part of the parent's implementation. The compiled
    # call graph misses these relationships when the nested module is
    # used only via struct construction (`%X{...}`) or pattern matching
    # (`%X{} = state`) — both of which compile to literal map ops with
    # `:__struct__` keys, NOT remote `__struct__/1` calls. So the BEAM's
    # `:imports` chunk has zero edges from parent to such nested modules.
    #
    # Fix: treat lexical nesting as a virtual edge. If the parent IS
    # anchored, the nested modules are too. If the parent isn't, the
    # nested modules being unreachable is the parent's problem, not
    # Archdo's.

    test "no nested modules returns empty map" do
      code = ~S"""
      defmodule Plain do
        def go, do: :ok
      end
      """

      assert NestedModules.extract(parse!(code)) == %{}
    end

    test "single nested module produces one parent→child edge" do
      code = ~S"""
      defmodule Outer do
        defmodule Inner do
          defstruct [:foo]
        end
      end
      """

      assert NestedModules.extract(parse!(code)) == %{"Outer" => ["Outer.Inner"]}
    end

    test "multiple nested modules at the same level dedup nothing — distinct names" do
      code = ~S"""
      defmodule MyApp.Adapter do
        defmodule State do
          defstruct [:foo]
        end

        defmodule Subscriber do
          defstruct [:bar]
        end
      end
      """

      edges = NestedModules.extract(parse!(code))

      assert "MyApp.Adapter.State" in edges["MyApp.Adapter"]
      assert "MyApp.Adapter.Subscriber" in edges["MyApp.Adapter"]
    end

    test "deeply nested modules produce a chain of edges" do
      code = ~S"""
      defmodule A do
        defmodule B do
          defmodule C do
            def go, do: :ok
          end
        end
      end
      """

      edges = NestedModules.extract(parse!(code))

      assert edges["A"] == ["A.B"]
      assert edges["A.B"] == ["A.B.C"]
    end

    test "compound parent alias (defmodule Foo.Bar do)" do
      # Elixir allows `defmodule Foo.Bar do ... end` — the parts list
      # is [Foo, Bar]. A nested `defmodule Baz` inside that becomes
      # `Foo.Bar.Baz`.
      code = ~S"""
      defmodule Foo.Bar do
        defmodule Baz do
          def go, do: :ok
        end
      end
      """

      assert NestedModules.extract(parse!(code)) == %{"Foo.Bar" => ["Foo.Bar.Baz"]}
    end

    test "compound nested alias (defmodule Outer.Sub.Inner do)" do
      # `defmodule Outer do; defmodule Sub.Inner do; ... end; end` →
      # nested becomes `Outer.Sub.Inner` (Elixir prepends parent prefix).
      code = ~S"""
      defmodule Outer do
        defmodule Sub.Inner do
          def go, do: :ok
        end
      end
      """

      assert NestedModules.extract(parse!(code)) == %{"Outer" => ["Outer.Sub.Inner"]}
    end

    test "ignores defmodule inside a defmacro body (already handled by MacroEdges)" do
      # A `defmodule` quoted inside `defmacro` ends up in the consumer's
      # module, not lexically inside the LIBRARY's. Don't claim a
      # lexical-container edge here — it would be wrong.
      code = ~S"""
      defmodule MyMacroLib do
        defmacro __using__(_opts) do
          quote do
            defmodule InjectedIntoConsumer do
              def go, do: :ok
            end
          end
        end
      end
      """

      assert NestedModules.extract(parse!(code)) == %{}
    end

    test "non-module top-level returns empty map" do
      code = ~S"""
      :ok
      """

      assert NestedModules.extract(parse!(code)) == %{}
    end
  end

  defp parse!(code), do: Code.string_to_quoted!(code)
end
