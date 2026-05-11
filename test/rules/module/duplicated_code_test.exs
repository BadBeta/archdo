defmodule Archdo.Rules.Module.DuplicatedCodeTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.DuplicatedCode

  defp parse(code, file) do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true)
    {file, ast}
  end

  describe "duplicate detection" do
    test "detects structurally identical functions across files" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.Orders do
            def calculate_total(items) do
              items
              |> Enum.map(fn item -> item.price * item.quantity end)
              |> Enum.sum()
              |> apply_tax(0.08)
              |> round_to_cents()
            end

            defp apply_tax(amount, rate), do: amount * (1 + rate)
            defp round_to_cents(amount), do: Float.round(amount, 2)
          end
          """,
          "lib/orders.ex"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.Invoices do
            def compute_amount(line_items) do
              line_items
              |> Enum.map(fn line -> line.price * line.quantity end)
              |> Enum.sum()
              |> apply_tax(0.08)
              |> round_to_cents()
            end

            defp apply_tax(value, percent), do: value * (1 + percent)
            defp round_to_cents(value), do: Float.round(value, 2)
          end
          """,
          "lib/invoices.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert [_ | _] = diags

      main =
        Enum.find(diags, &(&1.message =~ "compute_amount" or &1.message =~ "calculate_total"))

      assert main
      assert main.severity == :warning
    end

    test "ignores standard callbacks" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.ServerA do
            use GenServer
            def init(_), do: {:ok, %{}}
            def handle_call(:foo, _from, state), do: {:reply, :ok, state}
          end
          """,
          "lib/server_a.ex"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.ServerB do
            use GenServer
            def init(_), do: {:ok, %{}}
            def handle_call(:foo, _from, state), do: {:reply, :ok, state}
          end
          """,
          "lib/server_b.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert diags == []
    end

    test "ignores trivial small functions" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.A do
            def foo, do: :ok
          end
          """,
          "lib/a.ex"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.B do
            def foo, do: :ok
          end
          """,
          "lib/b.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert diags == []
    end

    test "ignores duplicates within the same file" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.A do
            def big_one(items) do
              items
              |> Enum.map(fn x -> x * x end)
              |> Enum.sum()
              |> Kernel.+(100)
              |> Kernel.*(2)
            end

            def big_two(stuff) do
              stuff
              |> Enum.map(fn x -> x * x end)
              |> Enum.sum()
              |> Kernel.+(100)
              |> Kernel.*(2)
            end
          end
          """,
          "lib/a.ex"
        )

      diags = DuplicatedCode.analyze_project([file1])
      # Same-file duplicates are caller's choice (could be intentional)
      assert diags == []
    end

    test "ignores test files" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.UserTest do
            def setup_user(id) do
              %User{id: id, name: "Test", email: "test@example.com", active: true}
              |> Repo.insert!()
              |> Map.put(:foo, :bar)
            end
          end
          """,
          "test/user_test.exs"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.AccountTest do
            def setup_account(id) do
              %Account{id: id, name: "Test", email: "test@example.com", active: true}
              |> Repo.insert!()
              |> Map.put(:foo, :bar)
            end
          end
          """,
          "test/account_test.exs"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert diags == []
    end
  end

  describe "umbrella sibling clones (D12)" do
    test "downgrades to :info when clones live in different umbrella sibling apps" do
      # Same code in two umbrella sibling apps. The duplication is
      # often deliberate (shared schema fields, parallel implementations
      # for different runtime targets); fire as :info, not :warning.
      shared_body = ~S"""
        def calculate_total(items) do
          items
          |> Enum.map(fn item -> item.price * item.quantity end)
          |> Enum.sum()
          |> apply_tax(0.08)
          |> round_to_cents()
        end

        defp apply_tax(amount, rate), do: amount * (1 + rate)
        defp round_to_cents(amount), do: Float.round(amount, 2)
      """

      file1 =
        parse(
          "defmodule Api.Orders do\n#{shared_body}end\n",
          "apps/api/lib/api/orders.ex"
        )

      file2 =
        parse(
          "defmodule Edge.Orders do\n#{shared_body}end\n",
          "apps/edge/lib/edge/orders.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert [diag | _] = diags
      assert diag.severity == :info, "Expected :info, got #{diag.severity}"
    end

    test "keeps :warning when both clones live in the same umbrella sibling app" do
      shared_body = ~S"""
        def calculate_total(items) do
          items
          |> Enum.map(fn item -> item.price * item.quantity end)
          |> Enum.sum()
          |> apply_tax(0.08)
          |> round_to_cents()
        end

        defp apply_tax(amount, rate), do: amount * (1 + rate)
        defp round_to_cents(amount), do: Float.round(amount, 2)
      """

      file1 =
        parse(
          "defmodule Api.Orders do\n#{shared_body}end\n",
          "apps/api/lib/api/orders.ex"
        )

      file2 =
        parse(
          "defmodule Api.Invoices do\n#{shared_body}end\n",
          "apps/api/lib/api/invoices.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert [diag | _] = diags
      assert diag.severity == :warning
    end

    test "keeps :warning for non-umbrella projects (no apps/ prefix)" do
      shared_body = ~S"""
        def calculate_total(items) do
          items
          |> Enum.map(fn item -> item.price * item.quantity end)
          |> Enum.sum()
          |> apply_tax(0.08)
          |> round_to_cents()
        end

        defp apply_tax(amount, rate), do: amount * (1 + rate)
        defp round_to_cents(amount), do: Float.round(amount, 2)
      """

      file1 =
        parse(
          "defmodule MyApp.Orders do\n#{shared_body}end\n",
          "lib/my_app/orders.ex"
        )

      file2 =
        parse(
          "defmodule MyApp.Invoices do\n#{shared_body}end\n",
          "lib/my_app/invoices.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      assert [diag | _] = diags
      assert diag.severity == :warning
    end
  end

  describe "false-positive guards" do
    test "different module attributes are NOT flagged as duplicates" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.PassFinder do
            @rule_passes %{"1.1" => 1, "2.3" => 2, "4.5" => 3}
            def pass_for(rule_id) when is_binary(rule_id), do: Map.get(@rule_passes, rule_id)
          end
          """,
          "lib/pass_finder.ex"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.GuardChecker do
            @guard_type_map %{is_binary: :string, is_integer: :int, is_atom: :atom}
            def guard_to_type(guard_fn) when is_atom(guard_fn), do: Map.get(@guard_type_map, guard_fn)
          end
          """,
          "lib/guard_checker.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])

      refute Enum.any?(diags, &(&1.message =~ "pass_for" or &1.message =~ "guard_to_type")),
             "different @attr references should not be considered structural clones"
    end

    test "same @attr in two modules IS still flagged (real clone of attribute lookup)" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.UserCache do
            @cache_table :users
            def fetch(key) when is_binary(key), do: Map.get(@cache_table, key)
          end
          """,
          "lib/user_cache.ex"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.OtherUserCache do
            @cache_table :users
            def lookup(id) when is_binary(id), do: Map.get(@cache_table, id)
          end
          """,
          "lib/other_user_cache.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])
      # Both fetch/1 and lookup/1 reference the same @cache_table — real clone
      assert Enum.any?(diags, &(&1.message =~ "fetch" or &1.message =~ "lookup")),
             "same @attr referenced by two functions IS a real cross-module clone"
    end

    test "functions with different arity are NOT flagged even if body shape coincides" do
      # Bodies large enough to exceed the @min_node_count threshold.
      file1 =
        parse(
          ~S"""
          defmodule MyApp.A do
            def make_pair(from, to) do
              first = String.upcase(from)
              second = String.upcase(to)
              [{first, second, :pair, :tag, :type, :metadata}]
            end
          end
          """,
          "lib/a.ex"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.B do
            def select(true, x, y, _label) do
              first = String.upcase(x)
              second = String.upcase(y)
              [{first, second, :pair, :tag, :type, :metadata}]
            end
          end
          """,
          "lib/b.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])

      refute Enum.any?(diags, &(&1.message =~ "make_pair" or &1.message =~ "select")),
             "different arities should not be considered structural clones"
    end

    test "functions with same body but different guards are NOT duplicates" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.A do
            def unwrap_atom({:__block__, _, [a]}) when is_atom(a), do: a
            def unwrap_atom(a) when is_atom(a), do: a
            def unwrap_atom(_), do: nil
          end
          """,
          "lib/a.ex"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.B do
            def unwrap_string({:__block__, _, [s]}) when is_binary(s), do: s
            def unwrap_string(s) when is_binary(s), do: s
            def unwrap_string(_), do: nil
          end
          """,
          "lib/b.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])

      refute Enum.any?(diags, &(&1.message =~ "unwrap_atom" or &1.message =~ "unwrap_string")),
             "guards (is_atom vs is_binary) discriminate semantically — must not collide"
    end

    test "predicates with same body shape but different head patterns are NOT duplicates" do
      file1 =
        parse(
          ~S"""
          defmodule MyApp.A do
            def catch_all_arg?({:_, _, ctx}) when is_atom(ctx), do: true
            def catch_all_arg?({var, _, ctx}) when is_atom(var) and is_atom(ctx), do: true
            def catch_all_arg?(_), do: false
          end
          """,
          "lib/a.ex"
        )

      file2 =
        parse(
          ~S"""
          defmodule MyApp.B do
            def def_node?({:def, _, [{name, _, _} | _]}) when is_atom(name), do: true
            def def_node?({:def, _, [{:when, _, [{name, _, _} | _]} | _]}) when is_atom(name), do: true
            def def_node?(_), do: false
          end
          """,
          "lib/b.ex"
        )

      diags = DuplicatedCode.analyze_project([file1, file2])

      refute Enum.any?(diags, &(&1.message =~ "catch_all_arg?" or &1.message =~ "def_node?")),
             "predicates discriminating different patterns must not be flagged as duplicates"
    end

    test "multi-clause heads of the same function do NOT self-clone within a file" do
      file =
        parse(
          ~S"""
          defmodule MyApp.Walker do
            def walk(nil, acc), do: acc
            def walk({_form, _meta, args}, acc) when is_list(args), do: Enum.reduce(args, acc, &walk/2)
            def walk(list, acc) when is_list(list), do: Enum.reduce(list, acc, &walk/2)
            def walk({a, b}, acc) do
              acc |> then(&walk(a, &1)) |> then(&walk(b, &1))
            end
            def walk(_, acc), do: acc
          end
          """,
          "lib/walker.ex"
        )

      diags = DuplicatedCode.analyze_project([file])

      # walk/2 has 5 clauses; some bodies match shape. Without aggregation
      # the rule reports them as N self-clones. With aggregation, the
      # whole function is one entry — no self-clone within a single file.
      refute Enum.any?(diags, &(&1.message =~ "walk")),
             "multi-clause heads should aggregate, not self-clone"
    end
  end

  describe "clone cohort detection (M-fb-F6)" do
    @cohort_body ~S"""
      def emit(unit) do
        unit
        |> validate()
        |> compile()
        |> write()
      end

      defp validate(unit), do: {:ok, unit}
      defp compile(unit), do: {:ok, unit}
      defp write(unit), do: :ok
    """

    defp cohort_module(mod_name, path) do
      parse(
        "defmodule #{mod_name} do\n" <> @cohort_body <> "\nend\n",
        path
      )
    end

    test "3 clones in the same parent dir → cohort title" do
      file_asts = [
        cohort_module("UA.Generator.A", "lib/ua/generator/a.ex"),
        cohort_module("UA.Generator.B", "lib/ua/generator/b.ex"),
        cohort_module("UA.Generator.C", "lib/ua/generator/c.ex")
      ]

      diags = DuplicatedCode.analyze_project(file_asts)
      titles = Enum.map(diags, & &1.title)

      assert Enum.any?(titles, &(&1 =~ "Cohort clone"))
      # The "under <layer>/" text should mention generator
      assert Enum.any?(diags, fn d -> d.title =~ "generator" or d.message =~ "generator/" end)
    end

    test "2 clones in same dir → original title (cohort needs 3+)" do
      file_asts = [
        cohort_module("UA.Generator.A", "lib/ua/generator/a.ex"),
        cohort_module("UA.Generator.B", "lib/ua/generator/b.ex")
      ]

      diags = DuplicatedCode.analyze_project(file_asts)
      titles = Enum.map(diags, & &1.title)

      refute Enum.any?(titles, &(&1 =~ "Cohort clone"))
      assert Enum.any?(titles, &(&1 =~ "Structurally identical"))
    end

    test "3+ clones spread across different dirs → original title" do
      file_asts = [
        cohort_module("MyApp.Generator.A", "lib/my_app/generator/a.ex"),
        cohort_module("MyApp.Worker.B", "lib/my_app/worker/b.ex"),
        cohort_module("MyApp.Cache.C", "lib/my_app/cache/c.ex")
      ]

      diags = DuplicatedCode.analyze_project(file_asts)
      titles = Enum.map(diags, & &1.title)

      refute Enum.any?(titles, &(&1 =~ "Cohort clone"))
    end
  end
end
