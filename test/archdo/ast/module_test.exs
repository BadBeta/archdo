defmodule Archdo.AST.ModuleTest do
  use ExUnit.Case, async: true

  alias Archdo.AST.Module, as: AstModule

  describe "name/1" do
    test "atoms strip the Elixir. prefix" do
      assert "MyApp.Accounts" = AstModule.name(MyApp.Accounts)
    end

    test "strings strip the Elixir. prefix" do
      assert "MyApp.Accounts" = AstModule.name("Elixir.MyApp.Accounts")
    end

    test "strings without prefix pass through unchanged" do
      assert "MyApp.Accounts" = AstModule.name("MyApp.Accounts")
    end
  end

  describe "body/1" do
    defp parse(code) do
      {:ok, ast} = Code.string_to_quoted(code)
      ast
    end

    test "returns the statement list of a module body" do
      ast = parse("defmodule M do\n  def f, do: 1\n  def g, do: 2\nend")
      [_def_f, _def_g] = AstModule.body(ast)
    end

    test "returns a single-element list for a single-statement body" do
      ast = parse("defmodule M do\n  def f, do: 1\nend")
      assert [_one] = AstModule.body(ast)
    end

    test "returns [] for non-module nodes" do
      assert [] = AstModule.body({:foo, [], nil})
    end
  end

  describe "under_namespace?/2" do
    test "true when the name IS the namespace" do
      assert AstModule.under_namespace?("MyApp.Accounts", "MyApp.Accounts")
    end

    test "true when the name is nested under the namespace" do
      assert AstModule.under_namespace?("MyApp.Accounts.User", "MyApp.Accounts")
    end

    test "false for sibling namespaces" do
      refute AstModule.under_namespace?("MyApp.Catalog", "MyApp.Accounts")
    end

    test "false when the name shares a prefix but isn't actually nested" do
      # "MyApp.AccountsExt" starts with "MyApp.Accounts" but isn't under it.
      refute AstModule.under_namespace?("MyApp.AccountsExt", "MyApp.Accounts")
    end
  end
end
