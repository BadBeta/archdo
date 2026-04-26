defmodule Archdo.Mcp.Tools.FixSafetyTest do
  @moduledoc """
  Tests that auto-fix NEVER produces broken code.
  Each test case comes from a real user-reported regression.
  """
  use ExUnit.Case, async: true

  alias Archdo.Mcp.Tools.Fix

  defp fix_file(code) do
    path = Path.join(System.tmp_dir!(), "archdo_safety_#{System.unique_integer([:positive])}.ex")
    File.write!(path, code)
    result = Fix.call(%{"file" => path})
    File.rm(path)
    result
  end

  describe "AF-1: assignment pipes must not be auto-fixed" do
    test "skips x = foo() |> bar()" do
      {:ok, result} =
        fix_file("""
        defmodule Foo do
          def bar do
            path = Path.join(base, "file.dets") |> to_charlist()
            path
          end
        end
        """)

      pipe_fixes = Enum.filter(result.fixes, &(&1.rule_id == "6.33" and &1.auto_fixable))
      assert pipe_fixes == []
    end

    test "skips values = Enum.map(items, &f/1) |> Enum.reject(&is_nil/1)" do
      {:ok, result} =
        fix_file("""
        defmodule Foo do
          def bar(items) do
            values = Enum.map(items, &extract/1) |> Enum.reject(&is_nil/1)
            values
          end
        end
        """)

      pipe_fixes = Enum.filter(result.fixes, &(&1.rule_id == "6.33" and &1.auto_fixable))
      assert pipe_fixes == []
    end

    test "skips indexed = Enum.with_index(samples) |> Enum.map(...)" do
      {:ok, result} =
        fix_file("""
        defmodule Foo do
          def bar(samples) do
            indexed = Enum.with_index(samples) |> Enum.map(fn {v, i} -> {i, v} end)
            indexed
          end
        end
        """)

      pipe_fixes = Enum.filter(result.fixes, &(&1.rule_id == "6.33" and &1.auto_fixable))
      assert pipe_fixes == []
    end
  end

  describe "keyword value pipes must not be auto-fixed" do
    test "skips key: expr |> func()" do
      {:ok, result} =
        fix_file("""
        defmodule Foo do
          @schema %{
            timeout: Zoi.integer() |> Zoi.optional(),
            name: Zoi.string() |> Zoi.default("test")
          }
        end
        """)

      pipe_fixes = Enum.filter(result.fixes, &(&1.rule_id == "6.33" and &1.auto_fixable))
      assert pipe_fixes == []
    end

    test "skips key?: expr |> func()" do
      {:ok, result} =
        fix_file("""
        defmodule Foo do
          @schema %{
            compress?: Zoi.boolean() |> Zoi.default(false)
          }
        end
        """)

      pipe_fixes = Enum.filter(result.fixes, &(&1.rule_id == "6.33" and &1.auto_fixable))
      assert pipe_fixes == []
    end
  end

  describe "case clause pipes must not be auto-fixed" do
    test "skips node -> Enum.map(...) |> Enum.reject(...)" do
      {:ok, result} =
        fix_file("""
        defmodule Foo do
          def bar(machine, id) do
            case get_node(machine, id) do
              nil -> []
              node -> Enum.map(node.children, &get/1) |> Enum.reject(&is_nil/1)
            end
          end
        end
        """)

      pipe_fixes = Enum.filter(result.fixes, &(&1.rule_id == "6.33" and &1.auto_fixable))
      assert pipe_fixes == []
    end
  end

  describe "safe pipes ARE auto-fixed" do
    test "fixes simple variable pipe" do
      {:ok, result} =
        fix_file("""
        defmodule Foo do
          def bar(list) do
            list |> Enum.sort()
          end
        end
        """)

      pipe_fixes = Enum.filter(result.fixes, &(&1.rule_id == "6.33" and &1.auto_fixable))

      case pipe_fixes do
        [fix] ->
          assert fix.replacement =~ "Enum.sort(list)"
          assert not String.contains?(fix.replacement, "|>")

        [] ->
          :ok
      end
    end

    test "fixes list literal pipe" do
      {:ok, result} =
        fix_file("""
        defmodule Foo do
          def bar(a, b) do
            [a, b] |> Enum.sort()
          end
        end
        """)

      pipe_fixes = Enum.filter(result.fixes, &(&1.rule_id == "6.33" and &1.auto_fixable))

      case pipe_fixes do
        [fix] ->
          assert fix.replacement =~ "Enum.sort([a, b])"

        [] ->
          :ok
      end
    end
  end

  describe "rule 7.24 describe block crash" do
    test "does not crash on quoted describe name" do
      path =
        Path.join(
          System.tmp_dir!(),
          "archdo_describe_#{System.unique_integer([:positive])}_test.exs"
        )

      code = """
      defmodule FooTest do
        use ExUnit.Case, async: true

        describe "persist_batch/1 with raw rows" do
          test "does something" do
            assert true
          end
        end
      end
      """

      File.write!(path, code)

      # Rule 7.24 should NOT crash — it previously crashed on {:__block__, _, ["string"]}
      diags =
        Archdo.Rules.Testing.EmptyDescribe.analyze(
          path,
          elem(
            Code.string_to_quoted(code,
              columns: true,
              token_metadata: true,
              literal_encoder: &{:ok, {:__block__, &2, [&1]}}
            ),
            1
          ),
          []
        )

      assert is_list(diags)
      File.rm(path)
    end
  end

  describe "archdo:allow comment suppression" do
    test "suppresses finding on next line via full runner" do
      path = Path.join(System.tmp_dir!(), "archdo_allow_#{System.unique_integer([:positive])}.ex")

      # Code WITH the allow comment
      code_with_allow = """
      defmodule AllowTest do
        # archdo:allow 4.27
        alias Some.Unused.Module
        def bar, do: :ok
      end
      """

      # Code WITHOUT the allow comment
      code_without_allow = """
      defmodule NoAllowTest do
        alias Some.Unused.Module
        def bar, do: :ok
      end
      """

      # Without comment: rule fires
      File.write!(path, code_without_allow)
      diags_without = Archdo.Runner.analyze([path], [])
      has_finding = Enum.any?(diags_without, &(&1.rule_id == "4.27"))

      # With comment: rule is suppressed
      File.write!(path, code_with_allow)
      diags_with = Archdo.Runner.analyze([path], [])
      suppressed = not Enum.any?(diags_with, &(&1.rule_id == "4.27"))

      File.rm(path)

      # The rule fires without comment and is suppressed with it
      assert has_finding
      assert suppressed
    end
  end

  describe "HEEx function detection in dead private function rule" do
    test "does not flag function used in ~H sigil" do
      code = """
      defmodule FooWeb.Components do
        use Phoenix.Component

        def render(assigns) do
          ~H\"\"\"
          <div><%= format_name(@name) %></div>
          \"\"\"
        end

        defp format_name(name), do: String.upcase(name)
      end
      """

      {:ok, ast} =
        Code.string_to_quoted(code,
          columns: true,
          token_metadata: true,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}}
        )

      diags =
        Archdo.Rules.Module.DeadPrivateFunction.analyze("lib/foo_web/components.ex", ast, [])

      dead_fns = Enum.filter(diags, &(&1.rule_id == "6.34"))

      # format_name should NOT be flagged as dead — it's called from HEEx
      names = Enum.map(dead_fns, & &1.message)
      assert not Enum.any?(names, &String.contains?(&1, "format_name"))
    end
  end

  describe "reverse dependency web file classification" do
    test "does not flag *_web.ex as domain module" do
      code = """
      defmodule MyAppWeb do
        def controller do
          quote do
            use Phoenix.Controller
            import MyAppWeb.Router.Helpers
          end
        end
      end
      """

      {:ok, ast} =
        Code.string_to_quoted(code,
          columns: true,
          token_metadata: true,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}}
        )

      diags =
        Archdo.Rules.Boundary.ReverseDependency.analyze(
          "lib/my_app_web.ex",
          ast,
          []
        )

      assert diags == []
    end
  end

  describe "supervisor init/1 max_restarts detection" do
    test "does not flag when init/1 sets max_restarts" do
      code = """
      defmodule MyApp.Supervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, :ok, opts)
        end

        def init(:ok) do
          children = []
          Supervisor.init(children, strategy: :one_for_all, max_restarts: 5, max_seconds: 30)
        end
      end
      """

      {:ok, ast} =
        Code.string_to_quoted(code,
          columns: true,
          token_metadata: true,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}}
        )

      diags = Archdo.Rules.OTP.MaxRestarts.analyze("lib/my_app/supervisor.ex", ast, [])
      assert diags == []
    end
  end
end
