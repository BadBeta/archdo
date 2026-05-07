defmodule Archdo.Rules.Module.DynamicApplyFromInputTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.DynamicApplyFromInput

  describe "analyze/3 — apply/3 with variable module" do
    test "flags apply(mod_var, :fun_atom, args)" do
      code = ~S"""
      defmodule MyApp.Dispatch do
        def run(mod, args) do
          apply(mod, :perform, args)
        end
      end
      """

      diags = assert_flagged(DynamicApplyFromInput, code)
      diag = hd(diags)
      assert diag.severity == :error
      assert diag.title =~ "apply"
    end

    test "flags apply(mod_var, fun_var, args)" do
      code = ~S"""
      defmodule MyApp.Dispatch do
        def run(mod, fun, args) do
          apply(mod, fun, args)
        end
      end
      """

      assert_flagged(DynamicApplyFromInput, code)
    end

    test "flags Kernel.apply(mod_var, :perform, args)" do
      code = ~S"""
      defmodule MyApp.Dispatch do
        def run(mod, args) do
          Kernel.apply(mod, :perform, args)
        end
      end
      """

      assert_flagged(DynamicApplyFromInput, code)
    end
  end

  describe "analyze/3 — apply/3 with literal module + variable function" do
    test "flags apply(KnownMod, fun_var, args)" do
      code = ~S"""
      defmodule MyApp.Dispatch do
        def run(fun, args) do
          apply(MyApp.Worker, fun, args)
        end
      end
      """

      diags = assert_flagged(DynamicApplyFromInput, code)
      assert hd(diags).severity == :error
    end

    test "flags apply(__MODULE__, fun_var, args)" do
      code = ~S"""
      defmodule MyApp.Dispatch do
        def run(fun, args) do
          apply(__MODULE__, fun, args)
        end
      end
      """

      assert_flagged(DynamicApplyFromInput, code)
    end
  end

  describe "analyze/3 — apply/3 fully literal (allowed)" do
    test "allows apply(KnownMod, :literal_fun, args)" do
      code = ~S"""
      defmodule MyApp.Dispatch do
        def run(args) do
          apply(MyApp.Worker, :perform, args)
        end
      end
      """

      assert_clean(DynamicApplyFromInput, code)
    end

    test "allows apply(__MODULE__, :literal_fun, args)" do
      code = ~S"""
      defmodule MyApp.Dispatch do
        def run(args) do
          apply(__MODULE__, :perform, args)
        end
      end
      """

      assert_clean(DynamicApplyFromInput, code)
    end

    test "allows apply with unquote(...) — compile-time-built name" do
      # Pleroma-style: `apply(__MODULE__, unquote(:"#{x}_relation"), args)`
      # inside a macro generates a finite set of named functions, not a
      # user-controlled dispatch. The function name is determined at
      # compile time from a constant list, so it's not an RCE vector.
      code = ~S"""
      defmodule MyApp.Relations do
        for target <- [:blocked, :muted] do
          def unquote(:"#{target}_users")(user) do
            __MODULE__
            |> apply(unquote(:"#{target}_relation"), [user])
            |> Repo.all()
          end
        end
      end
      """

      assert_clean(DynamicApplyFromInput, code)
    end
  end

  describe "analyze/3 — apply/2 with variable function reference" do
    test "flags apply(fun_var, args)" do
      code = ~S"""
      defmodule MyApp.Dispatch do
        def run(fun, args) do
          apply(fun, args)
        end
      end
      """

      diags = assert_flagged(DynamicApplyFromInput, code)
      assert hd(diags).title =~ "apply"
    end

    test "allows apply(&Mod.fun/2, args)" do
      code = ~S"""
      defmodule MyApp.Dispatch do
        def run(args) do
          apply(&MyApp.Worker.perform/2, args)
        end
      end
      """

      assert_clean(DynamicApplyFromInput, code)
    end

    test "allows apply(fn x -> x + 1 end, [1])" do
      code = ~S"""
      defmodule MyApp.Dispatch do
        def run do
          apply(fn x -> x + 1 end, [1])
        end
      end
      """

      assert_clean(DynamicApplyFromInput, code)
    end
  end

  describe "analyze/3 — file scoping" do
    test "skips test files" do
      code = ~S"""
      defmodule MyApp.DispatchTest do
        def run(mod, args) do
          apply(mod, :perform, args)
        end
      end
      """

      assert analyze(DynamicApplyFromInput, code, file: "test/my_app/dispatch_test.exs") == []
    end
  end

  describe "Phoenix `apply(__MODULE__, action_name(conn), ...)` pattern" do
    # Phoenix's documented controller-action injection pattern. The
    # function name comes from `Phoenix.Controller.action_name/1`
    # which reads `conn.private.phoenix_action` — set by Phoenix's
    # router based on the matched route. NOT user input.
    test "does NOT flag `apply(__MODULE__, action_name(conn), args)` (Phoenix action pattern)" do
      code = ~S"""
      defmodule MyAppWeb.EpisodeController do
        use Phoenix.Controller

        def action(conn, _) do
          arg_list = [conn, conn.params, conn.assigns.podcast]
          apply(__MODULE__, action_name(conn), arg_list)
        end

        def show(conn, _params, _podcast), do: conn
      end
      """

      assert_clean(DynamicApplyFromInput, code, file: "lib/my_app_web/episode_controller.ex")
    end

    test "does NOT contribute extra findings on the function side for `apply(mod, action_name(conn), args)`" do
      # The Authorize plug pattern: apply(policy_module, action, [user]).
      # `policy_module` non-literal triggers apply3_module (correct — not
      # provable safe without taint analysis). But action_name(conn) is
      # Phoenix-routing-derived; should NOT add a SECOND finding.
      code = ~S"""
      defmodule MyAppWeb.Plugs.Authorize do
        import Plug.Conn

        def call(conn, policy_module) do
          action = action_name(conn)
          apply(policy_module, action, [conn.assigns.current_user])
        end
      end
      """

      diags = analyze(DynamicApplyFromInput, code, file: "lib/my_app_web/plugs/authorize.ex")
      # 1 finding for the variable module, NOT 2 (action_name is safe).
      assert length(diags) <= 1
    end
  end

  describe "MFA-tuple destructure pattern (`{m, f, a}`)" do
    # The standard OTP `{module, function, arguments}` 3-tuple is THE
    # canonical way to encode a function call in Elixir/Erlang
    # (Supervisor child specs, GenServer.start_link, application
    # callback module, every DSL that supports "call this MFA").
    # When a function destructures `{m, f, a}` from its parameter and
    # then `apply(m, f, a)`, it's the documented passthrough — the
    # tuple's source is the trusted DSL/config layer, not user input.
    test "does NOT flag `apply(m, f, a)` where m, f, a came from `{m, f, a}` destructure in same fn" do
      code = ~S"""
      defmodule MyApp.DSL do
        def default(%{default: {mod, func, args}}), do: apply(mod, func, args)
        def default(%{default: function}) when is_function(function, 0), do: function.()
        def default(%{default: value}), do: value
      end
      """

      assert_clean(DynamicApplyFromInput, code, file: "lib/my_app/dsl.ex")
    end

    test "does NOT flag MFA-tuple in a `case` clause pattern" do
      code = ~S"""
      defmodule MyApp.Bulk do
        def lazy_default(fun) do
          case fun do
            {m, f, a} -> apply(m, f, a)
            fun -> fun.()
          end
        end
      end
      """

      assert_clean(DynamicApplyFromInput, code, file: "lib/my_app/bulk.ex")
    end

    test "STILL flags `apply(mod, fun, args)` when none came from MFA-tuple destructure" do
      # Regression: a non-MFA-pattern `apply(m, f, a)` is still suspicious.
      code = ~S"""
      defmodule MyApp.D do
        def call(mod, fun) do
          apply(mod, fun, [])
        end
      end
      """

      diags = analyze(DynamicApplyFromInput, code, file: "lib/my_app/d.ex")
      assert length(diags) >= 1
    end
  end

  describe "user-defined function NAMED `apply` — head, not call" do
    # When a module defines `def apply(...)` (an operator-application
    # function on a struct, e.g. a binary or unary operator dispatcher),
    # the AST node `{:apply, meta, [args]}` appears as the function HEAD
    # — it is the function being defined, not a call to Kernel.apply.
    # The rule must distinguish definitions from invocations.

    test "does NOT flag `def apply(struct, a, b)` head" do
      code = ~S"""
      defmodule MyApp.Op do
        defstruct [:function]

        @spec apply(atom() | t(), term(), term()) :: term()
        def apply(%__MODULE__{function: fun}, a, b), do: fun.(a, b)
        def apply(name, a, b) when is_atom(name), do: fn_for(name).(a, b)

        defp fn_for(:plus), do: &Kernel.+/2
      end
      """

      assert_clean(DynamicApplyFromInput, code, file: "lib/my_app/op.ex")
    end

    test "does NOT flag `def apply(struct, a)` 2-arity head" do
      code = ~S"""
      defmodule MyApp.UnaryOp do
        defstruct [:function]

        @spec apply(atom() | t(), term()) :: term()
        def apply(%__MODULE__{function: fun}, a), do: fun.(a)
        def apply(name, a) when is_atom(name), do: fn_for(name).(a)

        defp fn_for(:identity), do: & &1
      end
      """

      assert_clean(DynamicApplyFromInput, code, file: "lib/my_app/unary_op.ex")
    end

    test "STILL flags `apply(mod, fun, args)` call when same module also defines `def apply`" do
      # Regression: defining `def apply/3` must NOT mask actual Kernel.apply
      # CALLS elsewhere in the module.
      code = ~S"""
      defmodule MyApp.Mixed do
        def apply(%{f: f}, a, b), do: f.(a, b)

        def dispatch(mod, fun_name, args) do
          apply(mod, fun_name, args)
        end
      end
      """

      diags = analyze(DynamicApplyFromInput, code, file: "lib/my_app/mixed.ex")
      assert length(diags) >= 1
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert DynamicApplyFromInput.id() == "5.51"
    end

    test "description mentions dynamic apply" do
      desc = DynamicApplyFromInput.description()
      assert desc =~ "apply" or desc =~ "dynamic"
    end
  end
end
