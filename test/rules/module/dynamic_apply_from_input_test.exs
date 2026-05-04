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
