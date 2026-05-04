defmodule Archdo.ASTTest do
  use ExUnit.Case, async: true

  alias Archdo.AST

  describe "parse_file/1" do
    test "parses a valid Elixir file" do
      path = Path.join(System.tmp_dir!(), "ast_test_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "defmodule Foo do\n  def bar, do: :ok\nend")

      try do
        assert {:ok, ast} = AST.parse_file(path)
        assert is_tuple(ast)
      after
        File.rm(path)
      end
    end

    test "returns error for missing file" do
      assert {:error, msg} = AST.parse_file("missing_#{:rand.uniform(100_000)}.ex")
      assert is_binary(msg)
    end

    test "returns error for invalid syntax" do
      path = Path.join(System.tmp_dir!(), "ast_bad_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "defmodule Foo do\n  def bar(\nend")

      try do
        assert {:error, _} = AST.parse_file(path)
      after
        File.rm(path)
      end
    end
  end

  describe "extract_module_name/1" do
    test "extracts module name from defmodule" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyApp.Workers.Processor do
          def run, do: :ok
        end
        """)

      assert AST.extract_module_name(ast) == "MyApp.Workers.Processor"
    end

    test "returns Unknown for non-module code" do
      {:ok, ast} = Code.string_to_quoted("1 + 2")
      assert AST.extract_module_name(ast) == "Unknown"
    end
  end

  describe "extract_functions/2" do
    test "extracts public functions" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          def public_one(x), do: x
          def public_two(a, b), do: a + b
          defp private_one(x), do: x * 2
        end
        """)

      fns = AST.extract_functions(ast, :public)
      names = Enum.map(fns, fn {name, _arity, _meta, _args, _body} -> name end)
      assert :public_one in names
      assert :public_two in names
      refute :private_one in names
    end

    test "extracts the actual function name from guarded clauses (not :when)" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          defp normalize(s) when is_binary(s), do: %{value: s}
          defp guard_only(x) when is_integer(x) and x > 0, do: x
        end
        """)

      fns = AST.extract_functions(ast, :all)
      names = Enum.map(fns, fn {name, _, _, _, _} -> name end)

      assert :normalize in names, "expected :normalize, got #{inspect(names)}"
      assert :guard_only in names, "expected :guard_only, got #{inspect(names)}"
      refute :when in names, "guard keyword must not surface as a function name"

      # Arity must reflect the head, not include the guard expression
      {:normalize, arity, _, _, _} = Enum.find(fns, fn {n, _, _, _, _} -> n == :normalize end)
      assert arity == 1
    end

    test "extracts all functions with :all" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          def pub(x), do: x
          defp priv(x), do: x
        end
        """)

      fns = AST.extract_functions(ast, :all)
      names = Enum.map(fns, fn {name, _, _, _, _} -> name end)
      assert :pub in names
      assert :priv in names
    end

    test "extracts only private functions with :private" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          def pub(x), do: x
          defp priv_one(x), do: x
          defp priv_guarded(s) when is_binary(s), do: s
        end
        """)

      fns = AST.extract_functions(ast, :private)
      names = Enum.map(fns, fn {name, _, _, _, _} -> name end)
      refute :pub in names
      assert :priv_one in names
      assert :priv_guarded in names
    end
  end

  describe "genserver_module?/1" do
    test "returns true for module with use GenServer" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyServer do
          use GenServer
        end
        """)

      assert AST.genserver_module?(ast)
    end

    test "returns true for module with GenServer callbacks" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyServer do
          def handle_call(:ping, _from, state), do: {:reply, :pong, state}
        end
        """)

      assert AST.genserver_module?(ast)
    end

    test "returns false for plain module" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyModule do
          def hello, do: :world
        end
        """)

      refute AST.genserver_module?(ast)
    end
  end

  describe "test_file?/1" do
    test "returns true for test files" do
      assert AST.test_file?("test/my_test.exs")
      assert AST.test_file?("test/support/helpers.ex")
    end

    test "returns false for lib files" do
      refute AST.test_file?("lib/my_app/worker.ex")
    end
  end

  describe "contains?/2" do
    test "finds matching nodes in AST" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          def bar, do: Logger.info("hello")
        end
        """)

      assert AST.contains?(ast, fn
               {{:., _, [{:__aliases__, _, [:Logger]}, :info]}, _, _} -> true
               _ -> false
             end)
    end

    test "returns false when no match" do
      {:ok, ast} = Code.string_to_quoted("defmodule Foo do\n  def bar, do: :ok\nend")

      refute AST.contains?(ast, fn
               {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "impl_callbacks/1" do
    test "returns {name, arity} for every def annotated with @impl" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyApp.Server do
          @impl true
          def init(arg), do: {:ok, arg}

          @impl GenServer
          def handle_call(:ping, _from, state), do: {:reply, :pong, state}

          # Plain def — not annotated
          def helper(x), do: x * 2
        end
        """)

      set = AST.impl_callbacks(ast)
      assert MapSet.member?(set, {:init, 1})
      assert MapSet.member?(set, {:handle_call, 3})
      refute MapSet.member?(set, {:helper, 1})
    end

    test "preserves the impl flag across @spec/@doc between @impl and def" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyApp.Server do
          @impl true
          @spec init(term()) :: {:ok, term()}
          @doc "Initializes the server."
          def init(arg), do: {:ok, arg}
        end
        """)

      assert MapSet.member?(AST.impl_callbacks(ast), {:init, 1})
    end

    test "handles multiple top-level defmodules per file" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyApp.NotFound do
          defexception [:message]
        end

        defmodule MyApp.PageLive do
          @impl true
          def mount(_, _, socket), do: {:ok, socket}
        end
        """)

      assert MapSet.member?(AST.impl_callbacks(ast), {:mount, 3})
    end

    test "non-impl other module attributes do not set the flag" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyApp.X do
          @doc "not an impl"
          def foo(x), do: x
        end
        """)

      refute MapSet.member?(AST.impl_callbacks(ast), {:foo, 1})
    end
  end

  describe "defimpl_callbacks/1" do
    test "returns {name, arity} for every def inside a defimpl block" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyApp.ReadOnly do
          defstruct [:path]
        end

        defimpl MyApp.FileSystem, for: MyApp.ReadOnly do
          def read(fs, path), do: File.read(Path.join(fs.path, path))
          def write(_, _, _), do: raise("not implemented")
        end
        """)

      set = AST.defimpl_callbacks(ast)
      assert MapSet.member?(set, {:read, 2})
      assert MapSet.member?(set, {:write, 3})
    end

    test "ignores defs outside defimpl blocks" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyApp.X do
          def outer(x), do: x
        end

        defimpl MyApp.Y, for: MyApp.X do
          def inner(_), do: :ok
        end
        """)

      set = AST.defimpl_callbacks(ast)
      assert MapSet.member?(set, {:inner, 1})
      refute MapSet.member?(set, {:outer, 1})
    end

    test "handles multiple defimpls in one file (different :for types)" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defimpl MyApp.Codec, for: MyApp.A do
          def encode(x), do: x
        end

        defimpl MyApp.Codec, for: MyApp.B do
          def encode(x), do: x
          def decode(x, opts), do: {x, opts}
        end
        """)

      set = AST.defimpl_callbacks(ast)
      assert MapSet.member?(set, {:encode, 1})
      assert MapSet.member?(set, {:decode, 2})
    end
  end

  describe "ast_size/1" do
    test "does not count token_metadata as part of node count" do
      # Production parse_file/1 uses `token_metadata: true` which attaches
      # rich line/column/token info to every node. ast_size MUST count only
      # the logical AST shape — not the metadata bloat. Without this, a
      # trivial controller action like `def foo, do: bar()` reports as
      # 60+ AST nodes (BUG-6 from hexpm field test); the 1.15 large-action
      # rule then trips on every action.
      path = Path.join(System.tmp_dir!(), "ast_size_#{:rand.uniform(1_000_000)}.ex")
      File.write!(path, "defmodule Foo do\n  def bar(x), do: x + 1\nend")

      try do
        {:ok, ast} = AST.parse_file(path)
        size = AST.ast_size(ast)

        # The logical shape: defmodule, alias, def-head, args, +, x, 1.
        # Around a dozen nodes. Definitely not in the hundreds.
        assert size < 30,
               "ast_size of `def bar(x), do: x + 1` should be < 30 (got #{size}); " <>
                 "metadata is being counted"
      after
        File.rm(path)
      end
    end

    test "still counts function-body complexity meaningfully" do
      # Even after stripping metadata, a body with more nodes should report
      # a higher size than a trivial body.
      {:ok, small} = Code.string_to_quoted("def f(x), do: x")

      {:ok, big} =
        Code.string_to_quoted("""
        def f(x) do
          if x > 0 do
            x * 2 + 1
          else
            -x - 1
          end
        end
        """)

      assert AST.ast_size(big) > AST.ast_size(small)
    end
  end

  describe "find_all/2" do
    test "collects all matching nodes" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          def a, do: Logger.info("one")
          def b, do: Logger.warning("two")
        end
        """)

      matches =
        AST.find_all(ast, fn
          {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} -> true
          _ -> false
        end)

      assert length(matches) == 2
    end
  end

  describe "internal_module?/1 with production parse_file (literal_encoder)" do
    # The production parse path wraps literals as {:__block__, _, [literal]}.
    # Patterns matching the bare literal silently miss; the rule then
    # falsely reports this is NOT an internal module.
    test "detects @moduledoc false in a file parsed by parse_file/1" do
      path = Path.join(System.tmp_dir!(), "ast_internal_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "defmodule Foo do\n  @moduledoc false\n  def bar, do: :ok\nend")

      try do
        assert {:ok, ast} = AST.parse_file(path)

        assert AST.internal_module?(ast),
               "internal_module?/1 must detect @moduledoc false on a parse_file/1 AST"
      after
        File.rm(path)
      end
    end

    test "returns false for a module that has a real @moduledoc string" do
      path = Path.join(System.tmp_dir!(), "ast_internal_#{:rand.uniform(100_000)}.ex")
      File.write!(path, ~s|defmodule Foo do\n  @moduledoc "real docs"\n  def bar, do: :ok\nend|)

      try do
        assert {:ok, ast} = AST.parse_file(path)
        refute AST.internal_module?(ast)
      after
        File.rm(path)
      end
    end
  end

  describe "extract_callbacks/1" do
    test "groups callbacks by name" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule MyServer do
          use GenServer

          def init(args), do: {:ok, args}
          def handle_call(:ping, _from, state), do: {:reply, :pong, state}
          def handle_cast(:reset, state), do: {:noreply, %{}}
          def handle_info(:tick, state), do: {:noreply, state}
        end
        """)

      callbacks = AST.extract_callbacks(ast)
      assert length(callbacks[:init]) == 1
      assert length(callbacks[:handle_call]) == 1
      assert length(callbacks[:handle_cast]) == 1
      assert length(callbacks[:handle_info]) == 1
    end
  end

  describe "short_name/1 (binary clause)" do
    test "returns the last dotted segment of a binary module name" do
      assert AST.short_name("MyApp.Accounts.User") == "User"
      assert AST.short_name("Foo") == "Foo"
    end

    test "still works for atoms" do
      assert AST.short_name(MyApp.Accounts.User) == "User"
    end
  end

  describe "safe_existing_atom/1" do
    test "returns the atom for an existing module name" do
      _ = MyApp.Pretendo
      assert AST.safe_existing_atom("MyApp.Pretendo") == MyApp.Pretendo
    end

    test "returns nil for an unknown module name" do
      assert AST.safe_existing_atom("Definitely.Not.A.Real.Module.#{:rand.uniform(99_999)}") ==
               nil
    end
  end

  describe "try_existing_atom/1" do
    test "returns {:ok, atom} when the atom exists" do
      :a_known_atom_for_test
      assert AST.try_existing_atom("a_known_atom_for_test") == {:ok, :a_known_atom_for_test}
    end

    test "returns :error when the atom doesn't exist" do
      assert AST.try_existing_atom("not_an_atom_#{:rand.uniform(99_999)}") == :error
    end
  end

  describe "mix_exs?/1" do
    test "true for paths ending in mix.exs" do
      assert AST.mix_exs?("mix.exs")
      assert AST.mix_exs?("apps/foo/mix.exs")
      assert AST.mix_exs?("/tmp/proj/mix.exs")
    end

    test "false for non-mix.exs paths" do
      refute AST.mix_exs?("lib/my_app.ex")
      refute AST.mix_exs?("config/config.exs")
    end
  end

  describe "path_contains_any?/2" do
    test "true when any marker is a substring" do
      assert AST.path_contains_any?("lib/foo/_controller.ex", ["_controller.ex", "/views/"])
      assert AST.path_contains_any?("lib/foo/views/x.ex", ["_controller.ex", "/views/"])
    end

    test "false when no marker matches" do
      refute AST.path_contains_any?("lib/foo/bar.ex", ["_controller.ex", "/views/"])
    end

    test "false for empty marker list" do
      refute AST.path_contains_any?("anything", [])
    end
  end

  describe "path_starts_with_any?/2" do
    test "true when file starts with any root" do
      assert AST.path_starts_with_any?("lib/api/foo.ex", ["lib/api/", "lib/web/"])
    end

    test "false otherwise" do
      refute AST.path_starts_with_any?("lib/internal/foo.ex", ["lib/api/", "lib/web/"])
    end
  end

  describe "module_under_namespace?/2" do
    test "true when the names are equal" do
      assert AST.module_under_namespace?("MyApp.Accounts", "MyApp.Accounts")
    end

    test "true when name is under the namespace" do
      assert AST.module_under_namespace?("MyApp.Accounts.User", "MyApp.Accounts")
    end

    test "false when name is a sibling, not a child" do
      refute AST.module_under_namespace?("MyApp.AccountsX", "MyApp.Accounts")
      refute AST.module_under_namespace?("MyApp.Other", "MyApp.Accounts")
    end
  end

  describe "repo_module?/1" do
    test "true when the last segment is :Repo" do
      assert AST.repo_module?([:MyApp, :Repo])
      assert AST.repo_module?([:Repo])
    end

    test "true when :Repo appears in the middle" do
      assert AST.repo_module?([:MyApp, :Repo, :Helpers])
    end

    test "false when no :Repo segment" do
      refute AST.repo_module?([:MyApp, :Accounts])
    end
  end

  describe "join_alias_parts/1" do
    test "joins atoms into a dotted name" do
      assert AST.join_alias_parts([:MyApp, :Accounts, :User]) == "MyApp.Accounts.User"
    end

    test "single segment" do
      assert AST.join_alias_parts([:Foo]) == "Foo"
    end
  end

  describe "parse_files/1" do
    test "returns {file, ast} tuples for parseable files; drops failures silently" do
      good = Path.join(System.tmp_dir!(), "parse_files_good_#{:rand.uniform(99_999)}.ex")
      bad = Path.join(System.tmp_dir!(), "parse_files_bad_#{:rand.uniform(99_999)}.ex")
      File.write!(good, "defmodule Good do\n  def x, do: 1\nend")
      File.write!(bad, "defmodule Bad do\n  def x, do: 1")

      try do
        result = AST.parse_files([good, bad, "/nonexistent/path/x.ex"])
        assert length(result) == 1
        assert [{^good, _ast}] = result
      after
        File.rm(good)
        File.rm(bad)
      end
    end
  end

  describe "module_file_map/1" do
    test "builds a {module_name => file} map" do
      ast1 =
        quote do
          defmodule MyApp.A do
            def x, do: 1
          end
        end

      ast2 =
        quote do
          defmodule MyApp.B do
            def y, do: 2
          end
        end

      map = AST.module_file_map([{"a.ex", ast1}, {"b.ex", ast2}])
      assert map["MyApp.A"] == "a.ex"
      assert map["MyApp.B"] == "b.ex"
    end
  end

  describe "collect_internal_modules/1" do
    test "collects only @moduledoc false modules" do
      private_ast =
        quote do
          defmodule MyApp.Private do
            @moduledoc false
            def x, do: 1
          end
        end

      public_ast =
        quote do
          defmodule MyApp.Public do
            @moduledoc "I am public."
            def y, do: 2
          end
        end

      result =
        AST.collect_internal_modules([
          {"private.ex", private_ast},
          {"public.ex", public_ast}
        ])

      assert MapSet.member?(result, "MyApp.Private")
      refute MapSet.member?(result, "MyApp.Public")
    end
  end

  describe "literal_true?/1" do
    test "matches the wrapped block form {:__block__, _, [true]}" do
      assert AST.literal_true?({:__block__, [], [true]})
    end

    test "matches the bare boolean true" do
      assert AST.literal_true?(true)
    end

    test "does not match false" do
      refute AST.literal_true?(false)
      refute AST.literal_true?({:__block__, [], [false]})
    end

    test "does not match other AST nodes" do
      refute AST.literal_true?({:==, [], [1, 1]})
      refute AST.literal_true?(nil)
      refute AST.literal_true?({:my_var, [], nil})
    end
  end

  describe "catch_all_pattern?/1" do
    test "matches the underscore pattern {:_, _, _}" do
      assert AST.catch_all_pattern?({:_, [], nil})
    end

    test "matches a regular variable (binds anything that follows)" do
      assert AST.catch_all_pattern?({:foo, [], Elixir})
    end

    test "EXCLUDES underscore-prefixed variables (idiomatic discard)" do
      # `_foo` signals "I know I'm ignoring this", not a wildcard the
      # caller forgot to constrain — both unreachable_clause and
      # defensive_nil_return treat these as deliberate, not catch-all.
      refute AST.catch_all_pattern?({:_x, [], Elixir})
      refute AST.catch_all_pattern?({:_anything, [], nil})
    end

    test "does not match literal patterns" do
      refute AST.catch_all_pattern?(:ok)
      refute AST.catch_all_pattern?({:ok, []})
      refute AST.catch_all_pattern?(42)
    end
  end

  describe "behaviour_or_protocol?/1" do
    test "true for @callback" do
      ast = quote do: (@callback do_thing() :: :ok)
      assert AST.behaviour_or_protocol?(ast)
    end

    test "true for defprotocol" do
      ast = quote do: (defprotocol MyProto, do: (def call(x)))
      assert AST.behaviour_or_protocol?(ast)
    end

    test "false for plain modules" do
      ast = quote(do: (defmodule MyMod, do: (def f, do: 1)))
      refute AST.behaviour_or_protocol?(ast)
    end
  end

  describe "dep_only_option?/1" do
    test "true for the bare {:only, _} keyword form" do
      assert AST.dep_only_option?([{:only, [:dev]}, {:runtime, false}])
    end

    test "true for the literal-encoded {{:__block__, _, [:only]}, _} form" do
      assert AST.dep_only_option?([{{:__block__, [], [:only]}, [:test]}])
    end

    test "false when the keyword list has no :only entry" do
      refute AST.dep_only_option?([{:runtime, false}, {:targets, [:host]}])
    end

    test "false for an empty keyword list" do
      refute AST.dep_only_option?([])
    end
  end

  describe "contains_raise?/1" do
    test "true when AST contains a raise" do
      ast = quote do: raise("boom")
      assert AST.contains_raise?(ast)
    end

    test "false for plain returns" do
      ast = quote do: {:ok, 1}
      refute AST.contains_raise?(ast)
    end
  end

  describe "contains_telemetry?/1" do
    test "true for :telemetry.span/3" do
      ast = quote do: :telemetry.span([:my_app, :op], %{}, fn -> {:ok, %{}} end)
      assert AST.contains_telemetry?(ast)
    end

    test "true for :telemetry.execute/3" do
      ast = quote do: :telemetry.execute([:my_app, :event], %{count: 1}, %{})
      assert AST.contains_telemetry?(ast)
    end

    test "false for unrelated calls" do
      ast = quote do: Logger.info("hi")
      refute AST.contains_telemetry?(ast)
    end
  end

  describe "contains_logger?/1" do
    test "true for Logger.info" do
      ast = quote do: Logger.info("hi")
      assert AST.contains_logger?(ast)
    end

    test "true for Logger.error / warning / debug / notice" do
      for level <- [:error, :warning, :debug, :notice] do
        # Build {Logger, level} call AST manually via quote unquote
        ast = quote do: unquote({{:., [], [{:__aliases__, [], [:Logger]}, level]}, [], ["msg"]})
        assert AST.contains_logger?(ast), "expected Logger.#{level} to be detected"
      end
    end

    test "false for unrelated calls" do
      ast = quote do: IO.puts("hi")
      refute AST.contains_logger?(ast)
    end
  end

  describe "extract_test_name/1" do
    test "returns a bare-string test name" do
      assert "renders home" = AST.extract_test_name(["renders home", [do: nil]])
    end

    test "returns a literal-encoded test name" do
      assert "wrapped" =
               AST.extract_test_name([{:__block__, [], ["wrapped"]}, [do: nil]])
    end

    test "returns (unknown) for non-string names" do
      assert "(unknown)" = AST.extract_test_name([{:foo, [], nil}])
      assert "(unknown)" = AST.extract_test_name([])
    end
  end

  describe "extract_test_blocks/1" do
    test "extracts a list of {name, meta, body} for each test block" do
      ast =
        quote do
          defmodule MyApp.Test do
            use ExUnit.Case
            test "first", do: assert(true)
            test "second", do: assert(true)
          end
        end

      blocks = AST.extract_test_blocks(ast)
      assert length(blocks) == 2
      names = Enum.map(blocks, fn {n, _meta, _body} -> n end)
      assert "first" in names
      assert "second" in names
    end

    test "returns body=nil for tests without a do-block" do
      ast =
        quote do
          test("no body")
        end

      blocks = AST.extract_test_blocks(ast)
      assert [{"no body", _meta, nil}] = blocks
    end

    test "returns [] when there are no tests" do
      ast =
        quote do
          defmodule X do
            def f, do: 1
          end
        end

      assert [] = AST.extract_test_blocks(ast)
    end
  end

  describe "callback_capture?/1" do
    test "matches an `fn` literal" do
      assert AST.callback_capture?({:fn, [], [{:->, [], [[], :ok]}]})
    end

    test "matches an & capture" do
      assert AST.callback_capture?({:&, [], [{:/, [], [{:Foo, [], Elixir}, 1]}]})
    end

    test "does not match other AST" do
      refute AST.callback_capture?({:my_var, [], nil})
      refute AST.callback_capture?(:atom)
      refute AST.callback_capture?(nil)
    end
  end
end
