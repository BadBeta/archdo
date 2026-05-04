defmodule Archdo.Rules.Composition.OrderedChainConstraintsTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Composition.OrderedChainConstraints

  describe "duplicate plug" do
    test "fires when the same plug is declared twice in one pipeline" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :browser do
          plug :accepts, ["html"]
          plug :fetch_session
          plug :protect_from_forgery
          plug :fetch_session
        end
      end
      """

      diags = assert_flagged(OrderedChainConstraints, code)
      assert Enum.any?(diags, &(&1.message =~ "duplicate"))
      assert hd(diags).rule_id == "10.6"
      assert hd(diags).severity == :warning
    end

    test "does not fire when the same plug name appears in two different pipelines" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :browser do
          plug :fetch_session
          plug :protect_from_forgery
        end

        pipeline :api do
          plug :fetch_session
        end
      end
      """

      assert_clean(OrderedChainConstraints, code)
    end
  end

  describe "auth-then-authz ordering" do
    test "fires when authz plug precedes auth plug" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :authed do
          plug :authorize
          plug :authenticate
        end
      end
      """

      diags = assert_flagged(OrderedChainConstraints, code)
      assert Enum.any?(diags, &(&1.message =~ "authz"))
    end

    test "does not fire when auth precedes authz" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :authed do
          plug :authenticate
          plug :authorize
        end
      end
      """

      assert_clean(OrderedChainConstraints, code)
    end

    test "does not fire when only auth or only authz is present" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :authed do
          plug :authenticate
        end

        pipeline :public do
          plug :authorize
        end
      end
      """

      assert_clean(OrderedChainConstraints, code)
    end
  end

  describe "parsers-before-session" do
    test "fires when Plug.Parsers comes after :fetch_session" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :api do
          plug :fetch_session
          plug Plug.Parsers, parsers: [:json], json_decoder: Jason
        end
      end
      """

      diags = assert_flagged(OrderedChainConstraints, code)
      assert Enum.any?(diags, &(&1.message =~ "Plug.Parsers"))
    end

    test "does not fire when parsers come before session" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :api do
          plug Plug.Parsers, parsers: [:json], json_decoder: Jason
          plug :fetch_session
        end
      end
      """

      assert_clean(OrderedChainConstraints, code)
    end
  end

  describe "browser pipeline missing CSRF protection" do
    test "fires when a browser-shaped pipeline lacks :protect_from_forgery" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :browser do
          plug :accepts, ["html"]
          plug :fetch_session
          plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
        end
      end
      """

      diags = assert_flagged(OrderedChainConstraints, code)
      assert Enum.any?(diags, &(&1.message =~ "protect_from_forgery"))
    end

    test "does not fire when CSRF protection is present" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :browser do
          plug :accepts, ["html"]
          plug :fetch_session
          plug :protect_from_forgery
        end
      end
      """

      assert_clean(OrderedChainConstraints, code)
    end

    test "does not fire when CSRF is provided by a sibling pipeline (composed via pipe_through)" do
      # Idiomatic Phoenix pattern: a separate `:csrf` pipeline that
      # routes compose with `pipe_through [:browser, :csrf]`. The
      # browser pipeline itself doesn't need :protect_from_forgery if
      # the file has a sibling pipeline that provides it.
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :browser do
          plug :accepts, ["html"]
          plug :fetch_session
          plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
        end

        pipeline :csrf do
          plug :protect_from_forgery
        end
      end
      """

      assert_clean(OrderedChainConstraints, code)
    end

    test "does not fire on api-shaped pipelines without CSRF" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :api do
          plug :accepts, ["json"]
        end
      end
      """

      assert_clean(OrderedChainConstraints, code)
    end
  end

  describe "non-router files" do
    test "does not fire on a file with no pipeline block" do
      code = ~S"""
      defmodule MyApp.Plain do
        def hello, do: :world
      end
      """

      assert_clean(OrderedChainConstraints, code)
    end

    test "test files are skipped" do
      code = ~S"""
      defmodule MyAppWeb.RouterTest do
        use Phoenix.Router

        pipeline :browser do
          plug :fetch_session
          plug :fetch_session
        end
      end
      """

      assert_clean(OrderedChainConstraints, code, file: "test/my_app_web/router_test.exs")
    end
  end

  describe "production parser form (literal_encoder wraps atoms)" do
    # The production parser uses `literal_encoder` so atom literals become
    # `{:__block__, _, [:atom]}`. Pipeline detection must handle this.
    test "fires on browser pipeline missing CSRF — production form" do
      file = "lib/my_app_web/router.ex"

      {:ok, ast} =
        Code.string_to_quoted(
          ~S"""
          defmodule MyAppWeb.Router do
            use Phoenix.Router

            pipeline :browser do
              plug :accepts, ["html"]
              plug :fetch_session
              plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
            end
          end
          """,
          file: file,
          columns: true,
          token_metadata: true,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}}
        )

      diags = OrderedChainConstraints.analyze(file, ast, [])
      assert Enum.any?(diags, &(&1.message =~ "protect_from_forgery"))
    end

    test "fires on duplicate plug — production form" do
      file = "lib/my_app_web/router.ex"

      {:ok, ast} =
        Code.string_to_quoted(
          ~S"""
          defmodule MyAppWeb.Router do
            use Phoenix.Router

            pipeline :browser do
              plug :accepts, ["html"]
              plug :fetch_session
              plug :protect_from_forgery
              plug :fetch_session
            end
          end
          """,
          file: file,
          columns: true,
          token_metadata: true,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}}
        )

      diags = OrderedChainConstraints.analyze(file, ast, [])
      assert Enum.any?(diags, &(&1.message =~ "duplicate"))
    end
  end
end
