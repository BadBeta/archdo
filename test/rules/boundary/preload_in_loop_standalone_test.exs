defmodule Archdo.Rules.Boundary.PreloadInLoopStandaloneTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Boundary.PreloadInLoop

  defp analyze(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    PreloadInLoop.analyze("lib/example.ex", ast, [])
  end

  test "flags Repo.preload inside Enum.map" do
    diags =
      analyze("""
      defmodule Foo do
        def bar(users) do
          Enum.map(users, fn user -> Repo.preload(user, :posts) end)
        end
      end
      """)

    assert [%{rule_id: "4.28"}] = diags
  end

  test "flags Repo.get inside Enum.each" do
    diags =
      analyze("""
      defmodule Foo do
        def bar(ids) do
          Enum.each(ids, fn id -> Repo.get(User, id) end)
        end
      end
      """)

    assert [%{rule_id: "4.28"}] = diags
  end

  test "clean: Repo.preload outside loop" do
    assert [] ==
             analyze("""
             defmodule Foo do
               def bar(user), do: Repo.preload(user, :posts)
             end
             """)
  end

  test "clean: Repo.all outside loop" do
    assert [] ==
             analyze("""
             defmodule Foo do
               def bar, do: Repo.all(User)
             end
             """)
  end
end
