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
end
