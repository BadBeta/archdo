defmodule Archdo.Rules.Module.StringLengthCheckTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.StringLengthCheck

  defp analyze(code) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    StringLengthCheck.analyze("lib/example.ex", ast, [])
  end

  test "flags String.length(s) == 0" do
    diags =
      analyze("""
      defmodule Foo do
        def empty?(s), do: String.length(s) == 0
      end
      """)

    assert [%{title: "String.length for empty check"}] = diags
  end

  test "flags String.length(s) > 0" do
    diags =
      analyze("""
      defmodule Foo do
        def present?(s), do: String.length(s) > 0
      end
      """)

    assert [%{title: "String.length for non-empty check"}] = diags
  end

  test "clean: String.length for actual length is fine" do
    assert [] ==
             analyze("""
             defmodule Foo do
               def long?(s), do: String.length(s) > 100
             end
             """)
  end

  test "clean: byte_size check is fine" do
    assert [] ==
             analyze("""
             defmodule Foo do
               def empty?(s), do: byte_size(s) == 0
             end
             """)
  end
end
