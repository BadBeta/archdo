defmodule Archdo.PiiSchemaTest do
  use ExUnit.Case, async: true

  alias Archdo.PiiSchema

  defp parse(code) do
    {:ok, ast} = Code.string_to_quoted(code, columns: true, token_metadata: true)
    ast
  end

  describe "pii_field?/1" do
    test "true for exact-match PII names" do
      for name <- [:email, :phone, :ssn, :dob, :date_of_birth, :national_id, :tax_id, :address] do
        assert PiiSchema.pii_field?(name), "expected #{name} to be PII"
      end
    end

    test "true for password-prefixed names" do
      assert PiiSchema.pii_field?(:password)
      assert PiiSchema.pii_field?(:password_hash)
      assert PiiSchema.pii_field?(:passport_number)
    end

    test "true for token-suffixed names" do
      assert PiiSchema.pii_field?(:reset_token)
      assert PiiSchema.pii_field?(:api_token)
    end

    test "false for ordinary fields" do
      refute PiiSchema.pii_field?(:name)
      refute PiiSchema.pii_field?(:title)
      refute PiiSchema.pii_field?(:created_at)
    end

    test "false for non-atom inputs" do
      refute PiiSchema.pii_field?("email")
      refute PiiSchema.pii_field?(nil)
    end
  end

  describe "default_patterns/0" do
    test "exposes exact, prefixes, suffixes keys" do
      patterns = PiiSchema.default_patterns()
      assert is_list(patterns.exact)
      assert is_list(patterns.prefixes)
      assert is_list(patterns.suffixes)
      assert :email in patterns.exact
      assert "password" in patterns.prefixes
      assert "_token" in patterns.suffixes
    end
  end

  describe "schema_info/1" do
    test "returns module/table/pii_fields when the schema has PII" do
      ast = parse(~S"""
      defmodule MyApp.User do
        use Ecto.Schema
        schema "users" do
          field :name, :string
          field :email, :string
          field :password_hash, :string
        end
      end
      """)

      info = PiiSchema.schema_info(ast)
      assert info.module == "MyApp.User"
      assert info.table == "users"
      assert :email in info.pii_fields
      assert :password_hash in info.pii_fields
      refute :name in info.pii_fields
    end

    test "returns nil when the schema has no PII fields" do
      ast = parse(~S"""
      defmodule MyApp.Post do
        use Ecto.Schema
        schema "posts" do
          field :title, :string
          field :body, :string
        end
      end
      """)

      assert PiiSchema.schema_info(ast) == nil
    end

    test "returns nil for non-schema modules" do
      ast = parse(~S"""
      defmodule MyApp.Plain do
        def f, do: 1
      end
      """)

      assert PiiSchema.schema_info(ast) == nil
    end
  end
end
