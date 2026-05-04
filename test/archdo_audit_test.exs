defmodule Archdo.AuditTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "print_building_blocks/1" do
    @describetag :tmp_dir

    defp write(tmp_dir, name, code) do
      path = Path.join(tmp_dir, name)
      path |> Path.dirname() |> File.mkdir_p!()
      File.write!(path, code)
    end

    test "prints sections and returns 0", %{tmp_dir: tmp_dir} do
      write(tmp_dir, "lib/sample.ex", ~S"""
      defmodule MyApp.Sample do
        @moduledoc "doc"
        @spec one(integer()) :: integer()
        def one(x), do: x
      end
      """)

      output = capture_io(fn -> assert 0 = Archdo.print_building_blocks([tmp_dir]) end)

      assert output =~ "Archdo — Building Block Audit"
      assert output =~ "Building-block MODULES"
      assert output =~ "Leaks summary:"
    end

    test "handles empty source tree without crashing", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))

      output = capture_io(fn -> assert 0 = Archdo.print_building_blocks([tmp_dir]) end)

      assert output =~ "Archdo — Building Block Audit"
      assert output =~ "(none —" or output =~ "0 of 0"
    end
  end
end
