defmodule Archdo.AST.StructRefsTest do
  use ExUnit.Case, async: true

  alias Archdo.AST.StructRefs

  describe "extract/1 — pure AST → struct-reference edges" do
    # Struct construction (`%Foo{...}`) and struct pattern matching
    # (`%Foo{} = x`) compile to literal map operations — no remote
    # `__struct__/1` call. The BEAM's `:imports` chunk has zero edges
    # from the using module to the struct's module. NestedModules covers
    # the case where the struct is a nested submodule; this module
    # covers the SIBLING case (e.g. Bandit.HTTP1.Handler constructs
    # `%Bandit.HTTP1.Socket{...}`; both are top-level modules).

    test "no struct references returns empty map" do
      code = ~S"""
      defmodule Plain do
        def go(x), do: x + 1
      end
      """

      assert StructRefs.extract(parse!(code)) == %{}
    end

    test "single struct construction produces one edge" do
      code = ~S"""
      defmodule MyApp.Handler do
        def init(opts), do: %MyApp.Socket{opts: opts}
      end
      """

      edges = StructRefs.extract(parse!(code))
      assert "MyApp.Socket" in Map.fetch!(edges, "MyApp.Handler")
    end

    test "struct pattern match produces an edge" do
      code = ~S"""
      defmodule MyApp.Handler do
        def handle(%MyApp.State{} = state), do: state
      end
      """

      edges = StructRefs.extract(parse!(code))
      assert "MyApp.State" in Map.fetch!(edges, "MyApp.Handler")
    end

    test "deduplicates multiple references to the same struct" do
      code = ~S"""
      defmodule MyApp.Handler do
        def init(opts), do: %MyApp.Socket{opts: opts}
        def update(%MyApp.Socket{} = s, k, v), do: %MyApp.Socket{s | k => v}
      end
      """

      edges = StructRefs.extract(parse!(code))
      socket_count = Enum.count(edges["MyApp.Handler"], &(&1 == "MyApp.Socket"))
      assert socket_count == 1
    end

    test "ignores `%__MODULE__{}` self-references" do
      # The module's own struct is NOT a virtual edge — the module IS
      # itself, no anchor propagation needed.
      code = ~S"""
      defmodule MyApp.Self do
        defstruct [:foo]
        def new(foo), do: %__MODULE__{foo: foo}
      end
      """

      assert StructRefs.extract(parse!(code)) == %{}
    end

    test "captures references to multiple distinct structs" do
      code = ~S"""
      defmodule MyApp.Mixer do
        def go(req) do
          state = %MyApp.State{req: req}
          %MyApp.Response{state: state}
        end
      end
      """

      edges = StructRefs.extract(parse!(code))
      mixer_edges = edges["MyApp.Mixer"]
      assert "MyApp.State" in mixer_edges
      assert "MyApp.Response" in mixer_edges
    end

    test "ignores struct references inside defmacro bodies" do
      # Same rationale as NestedModules / MacroEdges: structs inside
      # `defmacro` materialize in the consumer's compilation, not
      # lexically here. MacroEdges already extracts those.
      code = ~S"""
      defmodule MyMacroLib do
        defmacro use_socket do
          quote do
            %Consumer.Socket{foo: 1}
          end
        end
      end
      """

      assert StructRefs.extract(parse!(code)) == %{}
    end

    test "non-module input returns empty map" do
      assert StructRefs.extract(parse!(~S":ok")) == %{}
    end
  end

  defp parse!(code), do: Code.string_to_quoted!(code)
end
