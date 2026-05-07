defmodule Archdo.Rules.Module.DeadPrivateFunctionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.DeadPrivateFunction

  describe "dead private functions" do
    test "flags a private function that is never called" do
      code = ~S"""
      defmodule MyApp.Users do
        def create(attrs) do
          validate(attrs)
        end

        defp validate(attrs), do: attrs

        defp unused_helper(x), do: x * 2
      end
      """

      diagnostics = assert_flagged(DeadPrivateFunction, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "6.34"
      assert diag.severity == :warning
      assert diag.message =~ "unused_helper/1"
      assert diag.message =~ "never called"
    end

    test "flags multiple dead private functions" do
      code = ~S"""
      defmodule MyApp.Math do
        def add(a, b), do: a + b

        defp dead_one(x), do: x + 1
        defp dead_two(x, y), do: x + y
      end
      """

      diagnostics = assert_flagged(DeadPrivateFunction, code)
      assert length(diagnostics) == 2
      names = Enum.map(diagnostics, & &1.message)
      assert Enum.any?(names, &(&1 =~ "dead_one/1"))
      assert Enum.any?(names, &(&1 =~ "dead_two/2"))
    end

    test "does not flag multi-clause private function where one clause name is called" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          do_parse(input)
        end

        defp do_parse(""), do: :empty
        defp do_parse(str), do: String.trim(str)
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end
  end

  describe "clean code" do
    test "does not flag private functions that are called" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def register(attrs) do
          attrs
          |> build_user()
          |> validate()
        end

        defp build_user(attrs), do: Map.put(attrs, :id, 1)
        defp validate(user), do: {:ok, user}
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.UsersTest do
        defp unused_helper(x), do: x
      end
      """

      assert_clean(DeadPrivateFunction, code, file: "test/users_test.exs")
    end

    test "does not flag dunder functions" do
      code = ~S"""
      defmodule MyApp.CustomMacro do
        def hello, do: :world

        defp __before_compile__(env), do: env
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end

    test "does not flag sigil functions" do
      code = ~S"""
      defmodule MyApp.Sigils do
        def test, do: :ok

        defp sigil_x(string, _opts), do: string
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end
  end

  describe "edge cases" do
    test "handles functions with zero arity" do
      code = ~S"""
      defmodule MyApp.Config do
        def load do
          defaults()
        end

        defp defaults, do: %{timeout: 5000}
        defp unused_defaults, do: %{timeout: 3000}
      end
      """

      diagnostics = assert_flagged(DeadPrivateFunction, code)
      assert [diag] = diagnostics
      assert diag.message =~ "unused_defaults/0"
    end

    test "does not flag private functions called from embed_templates .heex files" do
      # `embed_templates "path/*"` compiles separate .heex files into the
      # module. Functions defined in the embedding module (often defp) are
      # referenced from those external templates. The dead-code check must
      # follow the glob and scan those .heex files as call sites — otherwise
      # every helper used only from a template appears dead.
      # (BUG-7 from phoenix_live_dashboard.)
      tmp = Path.join(System.tmp_dir!(), "archdo_embed_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(Path.join(tmp, "lib/layouts"))
      module_path = Path.join(tmp, "lib/layout_view.ex")
      template_path = Path.join(tmp, "lib/layouts/dash.html.heex")

      File.write!(module_path, """
      defmodule LayoutView do
        use Phoenix.Component
        embed_templates "layouts/*"

        defp csp_nonce(conn, type), do: conn.assigns[type]
        defp asset_path(conn, kind), do: "/assets/\#{kind}"
      end
      """)

      File.write!(template_path, """
      <link rel="stylesheet" nonce={csp_nonce(@conn, :style)} href={asset_path(@conn, :css)} />
      """)

      try do
        assert_clean(DeadPrivateFunction, File.read!(module_path), file: module_path)
      after
        File.rm_rf!(tmp)
      end
    end

    test "does not flag private function components called via HEEx <.tag />" do
      # Phoenix LiveView function components are defined as `defp` and called
      # from sibling templates with `<.name />` syntax — not `name(...)`.
      # Without HEEx tag-form recognition, the rule false-positives on every
      # private LiveView function component (BUG-4 from hexpm field test).
      code = ~S"""
      defmodule MyAppWeb.Footer do
        use Phoenix.Component
        def footer(assigns) do
          ~H"<footer><.footer_branding /><.footer_links class=\"mt\"/><.footer_copyright/></footer>"
        end
        defp footer_branding(assigns), do: ~H"<div>brand</div>"
        defp footer_links(assigns), do: ~H"<ul>links</ul>"
        defp footer_copyright(assigns), do: ~H"<small>c</small>"
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end

    test "distinguishes by arity when gap is more than one" do
      code = ~S"""
      defmodule MyApp.Helpers do
        def run do
          helper(1)
        end

        defp helper(x), do: x
        defp helper(x, y, z), do: x + y + z
      end
      """

      diagnostics = assert_flagged(DeadPrivateFunction, code)
      assert [diag] = diagnostics
      assert diag.message =~ "helper/3"
    end

    test "does not flag a private function called via paren-less pipe" do
      # `x |> foo` (no parens) parses as `{:foo, _, nil}` (variable
      # form) rather than `{:foo, _, []}` (call form). The walker
      # must recognize the pipe-RHS-as-call pattern.
      code = ~S"""
      defmodule MyApp.TFA do
        def totp(secret) do
          secret
          |> generate_hmac(30)
          |> hmac_dynamic_truncation
          |> generate_hotp
        end

        defp generate_hmac(_secret, _period), do: :ok
        defp hmac_dynamic_truncation(_hmac), do: 0
        defp generate_hotp(_truncated), do: 123
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end

    # F4: `plug :atom` registers a PRIVATE function as a Plug callback.
    # Plug invokes it via `apply(module, :atom, [conn, opts])` at runtime —
    # the function IS called, but only via the plug pipeline. Static
    # analysis sees `defp canonical_host` with no direct callsites and
    # falsely flags it. Real-world: algora's endpoint.ex.

    test "does not flag a private function registered as a Plug via `plug :atom`" do
      code = ~S"""
      defmodule MyAppWeb.Endpoint do
        use Phoenix.Endpoint, otp_app: :my_app

        plug :canonical_host

        defp canonical_host(conn, _opts), do: conn
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end

    test "does not flag plug fn with options form `plug :name, opts`" do
      code = ~S"""
      defmodule MyAppWeb.Endpoint do
        plug :require_auth, except: [:login, :register]

        defp require_auth(conn, _opts), do: conn
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end

    test "does not flag plug fns inside a Phoenix.Router pipeline block" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :api do
          plug :put_format
          plug :authenticate
        end

        defp put_format(conn, _opts), do: conn
        defp authenticate(conn, _opts), do: conn
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end

    test "does not flag fn called via `|> name(args)` pipe-with-parens form" do
      # F4: `|> validate_cron()` parses as `{:|>, _, [lhs, {:validate_cron, _, []}]}`.
      # The bare-call clause records `validate_cron/0` but the actual arity
      # called via pipe is `validate_cron/1`. Without the pipe-with-parens
      # clause, the rule misses the call. Real-world: lightning's
      # `Trigger.validate_cron/2` (default-arg form, called as `|> validate_cron()`).
      code = ~S"""
      defmodule MyApp.Trigger do
        def changeset(cs, attrs) do
          cs
          |> Ecto.Changeset.cast(attrs, [:cron])
          |> validate_cron()
        end

        defp validate_cron(changeset, _options \\ []) do
          changeset
        end
      end
      """

      assert_clean(DeadPrivateFunction, code)
    end

    test "STILL flags a private function NOT registered as a plug" do
      # Regression guard — adding plug-name capture must not blanket-suppress
      # everything. A def that has no caller AND is not a plug-registered name
      # still flags.
      code = ~S"""
      defmodule MyAppWeb.Endpoint do
        plug :canonical_host

        defp canonical_host(conn, _opts), do: conn
        defp truly_dead(x), do: x + 1
      end
      """

      [diag] = assert_flagged(DeadPrivateFunction, code)
      assert diag.message =~ "truly_dead"
    end
  end
end
