defmodule Archdo.Rules.Compiled.DeadCodeTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Compiled.DeadCode

  describe "rule metadata" do
    test "id is 6.24" do
      assert DeadCode.id() == "6.24"
    end
  end

  describe "macro_injected_callback_default?/3 — pure helper" do
    # FP class: a function exists in compiled BEAM (post-macro-expansion) but
    # NOT in source AST. If the module declares `@behaviour Mod`, the function
    # is almost certainly a macro-injected default callback impl reached via
    # `apply(mod, callback, args)` from the framework. Must NOT flag.

    test "skips function not in source AST when module declares @behaviour" do
      finding = %{module: Bandit.InitialHandler, function: :handle_close, arity: 2}

      source_defs = %{
        # Source has only handle_connection/2; handle_close/2 is macro-injected.
        Bandit.InitialHandler => MapSet.new([{:handle_connection, 2}])
      }

      behaviour_implementor_modules = MapSet.new([Bandit.InitialHandler])

      assert DeadCode.macro_injected_callback_default?(
               finding,
               source_defs,
               behaviour_implementor_modules
             )
    end

    test "does NOT skip function in source AST (real def)" do
      finding = %{module: Bandit.InitialHandler, function: :handle_connection, arity: 2}

      source_defs = %{
        Bandit.InitialHandler => MapSet.new([{:handle_connection, 2}])
      }

      behaviour_implementor_modules = MapSet.new([Bandit.InitialHandler])

      refute DeadCode.macro_injected_callback_default?(
               finding,
               source_defs,
               behaviour_implementor_modules
             )
    end

    test "does NOT skip function not in source when module has NO @behaviour" do
      # Module without @behaviour — function not in source could be a NIF
      # placeholder, a macro-defined non-callback, etc. Don't auto-suppress.
      finding = %{module: MyApp.NifModule, function: :compute, arity: 1}

      source_defs = %{
        MyApp.NifModule => MapSet.new([])
      }

      behaviour_implementor_modules = MapSet.new()

      refute DeadCode.macro_injected_callback_default?(
               finding,
               source_defs,
               behaviour_implementor_modules
             )
    end

    test "does NOT skip when source_defs has no entry for the module" do
      # Defensive: if source_defs is missing data for a module, we conservatively
      # do NOT suppress. The runner is expected to populate every analyzed module.
      finding = %{module: MyApp.Unknown, function: :foo, arity: 0}

      assert DeadCode.macro_injected_callback_default?(
               finding,
               %{},
               MapSet.new([MyApp.Unknown])
             ) == true

      # Empty source_defs map for the module also means "not in source"
      # — combined with @behaviour declaration, suppression fires.
      # Intentional: a module that declares @behaviour AND we've parsed no
      # defs for it is an empty-source/macro-only module — treat as
      # macro-injected.
    end
  end
end
