defmodule ArchdoTest do
  use ExUnit.Case

  @moduletag :self_analysis

  test "run returns diagnostics list" do
    diagnostics = Archdo.run(["lib"], [])
    assert is_list(diagnostics)
  end

  test "run with empty paths returns empty list" do
    diagnostics = Archdo.run([], [])
    assert diagnostics == []
  end

  test "run with non-existent path returns empty list" do
    diagnostics = Archdo.run(["non_existent_path_#{:rand.uniform(100_000)}"], [])
    assert diagnostics == []
  end

  test "run with :only filters to specific rules" do
    diagnostics = Archdo.run(["lib"], only: ["5.14"])

    for d <- diagnostics do
      assert d.rule_id == "5.14"
    end
  end

  test "run with :ignore excludes specific rules" do
    all = Archdo.run(["lib"], [])
    filtered = Archdo.run(["lib"], ignore: ["5.14"])

    assert length(filtered) <= length(all)
    refute Enum.any?(filtered, &(&1.rule_id == "5.14"))
  end

  test "all diagnostics have valid structure" do
    diagnostics = Archdo.run(["lib"], [])

    for d <- diagnostics do
      assert %Archdo.Diagnostic{} = d
      assert is_binary(d.rule_id)
      assert d.severity in [:error, :warning, :info]
      assert is_binary(d.title)
      assert is_binary(d.message)
      assert is_binary(d.why)
      assert is_binary(d.file)
      assert is_integer(d.line)
      assert is_list(d.alternatives)

      for fix <- d.alternatives do
        assert %Archdo.Fix{} = fix
        assert is_binary(fix.summary)
      end
    end
  end

  test "diagnostics are sorted by severity" do
    diagnostics = Archdo.run(["lib"], [])

    severity_values = %{error: 0, warning: 1, info: 2}

    diagnostics
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] ->
      assert {severity_values[a.severity], a.file, a.line} <=
               {severity_values[b.severity], b.file, b.line}
    end)
  end
end
