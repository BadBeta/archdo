defmodule Archdo.Rules.Module.DocFalseShouldBeDefpTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.DocFalseShouldBeDefp

  test "fires on `@doc false` immediately above a `def`" do
    code = ~S"""
    defmodule MyApp.Worker do
      @doc false
      def internal_helper(x), do: x + 1

      def public_thing(x), do: internal_helper(x) * 2
    end
    """

    diags = assert_flagged(DocFalseShouldBeDefp, code)
    assert hd(diags).rule_id == "6.87"
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "defp"
  end

  test "does NOT fire on `defp` (already private)" do
    code = ~S"""
    defmodule MyApp.Worker do
      defp internal_helper(x), do: x + 1

      def public_thing(x), do: internal_helper(x) * 2
    end
    """

    assert_clean(DocFalseShouldBeDefp, code)
  end

  test "does NOT fire on `@doc false` above a `@spec` or other attribute" do
    code = ~S"""
    defmodule MyApp.Worker do
      @doc false
      @spec internal_helper(integer()) :: integer()
      def internal_helper(x), do: x + 1
    end
    """

    # The @doc false is NEXT to the def (with @spec between). Still
    # the same anti-pattern — we DO fire here. Caller can use defp.
    diags = assert_flagged(DocFalseShouldBeDefp, code)
    assert hd(diags).rule_id == "6.87"
  end

  # `__name__/arity` (double-underscore prefix AND suffix) is the
  # established Elixir idiom for "public-but-internal" — public so
  # other modules in the same project can call it (a private cannot
  # cross module boundaries), but `@doc false` to hide from generated
  # docs and signal "don't depend on this from user code". Production
  # examples: `Phoenix.__init__/2`, `Plug.Conn.__protocol__/1`,
  # `Module.__info__/1`. The rule should NOT advise `defp` here —
  # `defp` would break cross-module callers.
  test "does NOT fire on `__name__/arity` cross-module-internal convention" do
    code = ~S"""
    defmodule MyApp.SchemaCompiler do
      @doc false
      def __opts_schema__, do: @opts_schema

      @doc false
      def __init__(env, opts), do: {env, opts}
    end
    """

    assert_clean(DocFalseShouldBeDefp, code)
  end

  test "does NOT fire on Supervisor/GenServer behaviour callbacks (child_spec, init, etc.)" do
    # `child_spec/1`, `init/1`, `start_link/1` etc. are framework
    # callbacks — the framework invokes them via apply/3. They MUST
    # be public; defp would break the framework. `@doc false` on
    # them just hides them from generated docs (the user-facing API
    # is `start_link/1` or similar, not the lifecycle callbacks).
    code = ~S"""
    defmodule MyApp.Worker do
      use Supervisor

      def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

      @doc false
      @spec child_spec([term()]) :: Supervisor.child_spec()
      def child_spec(opts) do
        opts |> super() |> Supervisor.child_spec(id: __MODULE__)
      end

      @doc false
      def init(opts), do: {:ok, opts}
    end
    """

    assert_clean(DocFalseShouldBeDefp, code)
  end

  test "does NOT fire on a `@doc false` overload when another arity has real `@doc`" do
    # Overload-with-shared-docs: `def insert/2` has `@doc false` (it's
    # a convenience overload), `def insert/3` has the canonical
    # `@doc "..."`. Both are public API; the `@doc false` just avoids
    # duplicating docs on the overload variant. Common in libraries
    # with multiple arities for ergonomic call sites.
    code = ~S'''
    defmodule MyApp.Inserter do
      @doc "Insert a changeset."
      def insert(name \\ __MODULE__, changeset, opts \\ [])

      def insert(name, changeset, opts), do: do_insert(name, changeset, opts)

      @doc false
      def insert(changeset, opts), do: insert(__MODULE__, changeset, opts)

      defp do_insert(_, _, _), do: :ok
    end
    '''

    assert_clean(DocFalseShouldBeDefp, code)
  end

  test "STILL fires on a `@doc false` def when no other arity of the same name has real `@doc`" do
    # Regression guard: a genuinely-private function masquerading as
    # @doc-false `def` should still flag.
    code = ~S"""
    defmodule MyApp.Worker do
      @doc false
      def truly_internal(x), do: x + 1
    end
    """

    assert_flagged(DocFalseShouldBeDefp, code)
  end
end
