defmodule Archdo.Rules.Module.SingleImplProtocolTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.SingleImplProtocol

  defp parse(file, code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {file, ast}
  end

  describe "analyze_project/1" do
    test "flags a protocol with exactly one impl" do
      file_asts = [
        parse("lib/myapp/renderable.ex", ~S"""
        defprotocol MyApp.Renderable do
          def render(item)
        end
        """),
        parse("lib/myapp/renderable/user.ex", ~S"""
        defimpl MyApp.Renderable, for: MyApp.User do
          def render(_), do: "user"
        end
        """)
      ]

      diags = SingleImplProtocol.analyze_project(file_asts)

      assert [diag] = diags
      assert diag.rule_id == "4.2"
      assert diag.context.protocol == "MyApp.Renderable"
      assert diag.context.implementation == "MyApp.User"
      assert diag.file == "lib/myapp/renderable.ex"
    end

    test "does NOT flag a protocol with two or more impls" do
      file_asts = [
        parse("lib/myapp/renderable.ex", ~S"""
        defprotocol MyApp.Renderable do
          def render(item)
        end
        """),
        parse("lib/myapp/renderable/user.ex", ~S"""
        defimpl MyApp.Renderable, for: MyApp.User do
          def render(_), do: "user"
        end
        """),
        parse("lib/myapp/renderable/post.ex", ~S"""
        defimpl MyApp.Renderable, for: MyApp.Post do
          def render(_), do: "post"
        end
        """)
      ]

      assert SingleImplProtocol.analyze_project(file_asts) == []
    end

    test "does NOT flag a protocol with zero impls (different concern)" do
      # Protocol-without-impl is a separate code smell (dead protocol);
      # the [impl] pattern in analyze_project requires exactly one,
      # so empty-impl protocols are silently skipped.
      file_asts = [
        parse("lib/myapp/empty.ex", ~S"""
        defprotocol MyApp.EmptyProto do
          def go(item)
        end
        """)
      ]

      assert SingleImplProtocol.analyze_project(file_asts) == []
    end

    test "ignores impls in test files (mock impls don't count)" do
      # A protocol with one prod impl and one test mock should still
      # fire — test_support files are filtered out before counting.
      file_asts = [
        parse("lib/myapp/storage.ex", ~S"""
        defprotocol MyApp.Storage do
          def read(key)
        end
        """),
        parse("lib/myapp/storage/disk.ex", ~S"""
        defimpl MyApp.Storage, for: MyApp.DiskStorage do
          def read(_), do: :ok
        end
        """),
        parse("test/support/storage_mock.ex", ~S"""
        defimpl MyApp.Storage, for: MyApp.MockStorage do
          def read(_), do: :ok
        end
        """)
      ]

      diags = SingleImplProtocol.analyze_project(file_asts)
      assert [diag] = diags
      assert diag.context.implementation == "MyApp.DiskStorage"
    end

    test "handles multiple distinct protocols in one project" do
      file_asts = [
        parse("lib/myapp/a.ex", ~S"""
        defprotocol MyApp.A do
          def x(item)
        end
        """),
        parse("lib/myapp/b.ex", ~S"""
        defprotocol MyApp.B do
          def y(item)
        end
        """),
        parse("lib/myapp/a_user.ex", ~S"""
        defimpl MyApp.A, for: MyApp.User do
          def x(_), do: :ok
        end
        """),
        parse("lib/myapp/b_user.ex", ~S"""
        defimpl MyApp.B, for: MyApp.User do
          def y(_), do: :ok
        end
        """),
        parse("lib/myapp/b_post.ex", ~S"""
        defimpl MyApp.B, for: MyApp.Post do
          def y(_), do: :ok
        end
        """)
      ]

      diags = SingleImplProtocol.analyze_project(file_asts)
      protocols = Enum.map(diags, & &1.context.protocol)

      assert protocols == ["MyApp.A"]
    end
  end
end
