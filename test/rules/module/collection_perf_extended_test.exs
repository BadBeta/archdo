defmodule Archdo.Rules.Module.CollectionPerfExtendedTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.CollectionPerf

  defp analyze(code) do
    {:ok, ast} = Code.string_to_quoted(code, columns: true, token_metadata: true,
      literal_encoder: &{:ok, {:__block__, &2, [&1]}})
    CollectionPerf.analyze("lib/example.ex", ast, [])
  end

  describe "filter |> map pipe detection" do
    test "flags 3-step pipe with filter then map" do
      diags = analyze("""
      defmodule Foo do
        def bar(list) do
          list
          |> Enum.filter(&is_integer/1)
          |> Enum.map(&to_string/1)
        end
      end
      """)

      assert [%{title: "Enum.filter |> Enum.map" <> _}] = diags
    end

    test "flags reject piped into map" do
      diags = analyze("""
      defmodule Foo do
        def bar(list) do
          list
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&to_string/1)
        end
      end
      """)

      assert [%{title: "Enum.filter |> Enum.map" <> _}] = diags
    end

    test "clean: filter alone is fine" do
      assert [] == analyze("""
      defmodule Foo do
        def bar(list), do: Enum.filter(list, &is_integer/1)
      end
      """)
    end

    test "clean: filter then sort is fine (not filter then map)" do
      assert [] == analyze("""
      defmodule Foo do
        def bar(list) do
          list
          |> Enum.filter(&is_integer/1)
          |> Enum.sort()
        end
      end
      """)
    end
  end

  describe "sort then first element" do
    test "flags Enum.sort |> hd in 3-step pipe" do
      diags = analyze("""
      defmodule Foo do
        def bar(list) do
          list |> Enum.sort() |> hd()
        end
      end
      """)

      assert [%{title: "Enum.sort to get first element"}] = diags
    end

    test "flags hd(Enum.sort(list))" do
      diags = analyze("""
      defmodule Foo do
        def bar(list), do: hd(Enum.sort(list))
      end
      """)

      assert [%{title: "Enum.sort to get first element"}] = diags
    end

    test "flags sort_by |> hd" do
      diags = analyze("""
      defmodule Foo do
        def bar(list) do
          list |> Enum.sort_by(& &1.age) |> hd()
        end
      end
      """)

      assert [%{title: "Enum.sort to get first element"}] = diags
    end

    test "clean: sort without hd is fine" do
      assert [] == analyze("""
      defmodule Foo do
        def bar(list), do: Enum.sort(list)
      end
      """)
    end
  end

  describe "double reverse" do
    test "flags nested Enum.reverse(Enum.reverse(x))" do
      diags = analyze("""
      defmodule Foo do
        def bar(list), do: Enum.reverse(Enum.reverse(list))
      end
      """)

      assert [%{title: "Double Enum.reverse" <> _}] = diags
    end

    test "clean: single reverse is fine" do
      assert [] == analyze("""
      defmodule Foo do
        def bar(list), do: Enum.reverse(list)
      end
      """)
    end
  end

  describe "Enum.member? in loop" do
    test "flags member? inside Enum.map callback" do
      diags = analyze("""
      defmodule Foo do
        def bar(items, allowed) do
          Enum.map(items, fn x -> Enum.member?(allowed, x) end)
        end
      end
      """)

      assert [%{title: "Enum.member?" <> _}] = diags
    end

    test "clean: member? outside loop is fine" do
      assert [] == analyze("""
      defmodule Foo do
        def bar(list, item), do: Enum.member?(list, item)
      end
      """)
    end

    test "clean: MapSet.member? in loop is fine" do
      assert [] == analyze("""
      defmodule Foo do
        def bar(items, set) do
          Enum.filter(items, fn x -> MapSet.member?(set, x) end)
        end
      end
      """)
    end
  end

  describe "Enum.count > 0" do
    test "flags Enum.count(list, fun) > 0" do
      diags = analyze("""
      defmodule Foo do
        def bar(list), do: Enum.count(list, &is_integer/1) > 0
      end
      """)

      assert [%{title: "Enum.count for boolean check"}] = diags
    end

    test "flags Enum.count(list, fun) == 0" do
      diags = analyze("""
      defmodule Foo do
        def bar(list), do: Enum.count(list, &is_integer/1) == 0
      end
      """)

      assert [%{title: "Enum.count for boolean check"}] = diags
    end
  end
end
