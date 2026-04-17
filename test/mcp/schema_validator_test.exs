defmodule Archdo.Mcp.SchemaValidatorTest do
  use ExUnit.Case, async: true

  alias Archdo.Mcp.SchemaValidator

  defmodule FakeTool do
    def input_schema do
      %{
        "type" => "object",
        "properties" => %{
          "paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"}
          },
          "severity" => %{
            "type" => "string",
            "enum" => ["info", "warning", "error"]
          }
        },
        "required" => ["paths"],
        "additionalProperties" => false
      }
    end
  end

  describe "validate/2" do
    test "returns ok for valid arguments" do
      assert {:ok, validated} = SchemaValidator.validate(FakeTool, %{"paths" => ["lib/"]})
      assert validated["paths"] == ["lib/"]
    end

    test "returns error for missing required field" do
      assert {:error, message} = SchemaValidator.validate(FakeTool, %{})
      assert message =~ "required"
    end

    test "returns error for wrong type" do
      assert {:error, message} = SchemaValidator.validate(FakeTool, %{"paths" => "not-a-list"})
      assert message =~ "type"
    end

    test "returns error for invalid enum value" do
      args = %{"paths" => ["lib/"], "severity" => "critical"}
      assert {:error, message} = SchemaValidator.validate(FakeTool, args)
      assert is_binary(message)
    end

    test "accepts valid enum value" do
      args = %{"paths" => ["lib/"], "severity" => "warning"}
      assert {:ok, _} = SchemaValidator.validate(FakeTool, args)
    end
  end
end
