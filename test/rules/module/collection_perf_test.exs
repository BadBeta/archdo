defmodule Archdo.Rules.Module.CollectionPerfTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.CollectionPerf

  defp analyze(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    CollectionPerf.analyze("lib/example.ex", ast, [])
  end

  describe "Enum.count > 0 → Enum.any?" do
    test "flags Enum.count(list, fun) > 0" do
      diags =
        analyze("""
        defmodule Foo do
          def bar(list) do
            Enum.count(list, &is_integer/1) > 0
          end
        end
        """)

      assert [%{title: "Enum.count for boolean check"}] = diags
    end

    test "clean: Enum.count without comparison is fine" do
      assert [] ==
               analyze("""
               defmodule Foo do
                 def bar(list), do: Enum.count(list, &is_integer/1)
               end
               """)
    end
  end

  describe "Enum.filter |> Enum.map" do
    test "flags filter piped into map" do
      diags =
        analyze("""
        defmodule Foo do
          def bar(list) do
            list
            |> Enum.filter(&is_integer/1)
            |> Enum.map(&to_string/1)
          end
        end
        """)

      assert [%{title: "Enum.filter |> Enum.map — two passes"}] = diags
    end

    test "clean: filter alone is fine" do
      assert [] ==
               analyze("""
               defmodule Foo do
                 def bar(list), do: Enum.filter(list, &is_integer/1)
               end
               """)
    end
  end

  describe "Enum.sort |> hd → Enum.min" do
    test "flags sort piped into hd" do
      diags =
        analyze("""
        defmodule Foo do
          def bar(list) do
            list |> Enum.sort() |> hd()
          end
        end
        """)

      assert [%{title: "Enum.sort to get first element"}] = diags
    end

    test "flags hd(Enum.sort(list))" do
      diags =
        analyze("""
        defmodule Foo do
          def bar(list), do: hd(Enum.sort(list))
        end
        """)

      assert [%{title: "Enum.sort to get first element"}] = diags
    end

    test "clean: Enum.sort alone is fine" do
      assert [] ==
               analyze("""
               defmodule Foo do
                 def bar(list), do: Enum.sort(list)
               end
               """)
    end
  end

  describe "double reverse" do
    test "flags Enum.reverse(Enum.reverse(list))" do
      diags =
        analyze("""
        defmodule Foo do
          def bar(list), do: Enum.reverse(Enum.reverse(list))
        end
        """)

      assert [%{title: "Double Enum.reverse — identity operation"}] = diags
    end

    test "clean: single reverse is fine" do
      assert [] ==
               analyze("""
               defmodule Foo do
                 def bar(list), do: Enum.reverse(list)
               end
               """)
    end
  end

  describe "Enum.member? in loop" do
    test "flags member? inside Enum.filter callback" do
      diags =
        analyze("""
        defmodule Foo do
          def bar(list, allowed) do
            Enum.filter(list, fn x -> Enum.member?(allowed, x) end)
          end
        end
        """)

      assert [%{title: "Enum.member? on list inside loop"}] = diags
    end

    test "clean: member? outside loop is fine" do
      assert [] ==
               analyze("""
               defmodule Foo do
                 def bar(list, item), do: Enum.member?(list, item)
               end
               """)
    end
  end
end
