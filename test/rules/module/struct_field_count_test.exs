defmodule Archdo.Rules.Module.StructFieldCountTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.StructFieldCount

  test "flags struct with 32+ fields as error" do
    fields = Enum.map_join(1..33, ", ", fn i -> ":field_#{i}" end)

    code = """
    defmodule MyApp.BigStruct do
      @moduledoc false
      defstruct [#{fields}]
    end
    """

    diags = assert_flagged(StructFieldCount, code)
    assert hd(diags).severity == :error
    assert hd(diags).message =~ "33 fields"
  end

  test "flags struct with 20+ fields as warning" do
    fields = Enum.map_join(1..22, ", ", fn i -> ":field_#{i}" end)

    code = """
    defmodule MyApp.MediumStruct do
      @moduledoc false
      defstruct [#{fields}]
    end
    """

    diags = assert_flagged(StructFieldCount, code)
    assert hd(diags).severity == :warning
  end

  test "allows struct with < 20 fields" do
    code = ~S"""
    defmodule MyApp.SmallStruct do
      @moduledoc false
      defstruct [:name, :email, :age]
    end
    """

    assert_clean(StructFieldCount, code)
  end
end
