defmodule ArchdoTest do
  use ExUnit.Case

  test "run returns diagnostics list" do
    diagnostics = Archdo.run(["lib"], [])
    assert is_list(diagnostics)
  end
end
