defmodule Archdo.Rules.Module.ModuleLengthTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ModuleLength

  describe "analyze/3" do
    @describetag :tmp_dir

    defp write_module(tmp_dir, name, line_count) do
      path = Path.join(tmp_dir, "#{name}.ex")

      content =
        ["defmodule MyApp.#{Macro.camelize(name)} do"] ++
          Enum.map(1..line_count, fn i -> "  def func_#{i}, do: #{i}" end) ++
          ["end"]

      File.write!(path, Enum.join(content, "\n"))

      {:ok, ast} =
        Code.string_to_quoted(
          File.read!(path),
          file: path,
          columns: true,
          token_metadata: true
        )

      {path, ast}
    end

    test "allows files up to 1000 lines (warn threshold)", %{tmp_dir: tmp_dir} do
      # 950 def lines + module wrapper = ~952 total — under the 1000 warn threshold
      {path, ast} = write_module(tmp_dir, "ok_module", 950)
      assert [] = ModuleLength.analyze(path, ast, [])
    end

    test "info-flags files over 1000 lines", %{tmp_dir: tmp_dir} do
      # 1100 def lines + wrapper > 1000 lines, < 2000 lines
      {path, ast} = write_module(tmp_dir, "long_module", 1100)
      diags = ModuleLength.analyze(path, ast, [])
      assert [d] = diags
      assert d.rule_id == "6.4"
      assert d.severity == :info
    end

    test "warning-flags files over 2000 lines (error threshold)", %{tmp_dir: tmp_dir} do
      {path, ast} = write_module(tmp_dir, "huge_module", 2100)
      diags = ModuleLength.analyze(path, ast, [])
      assert [d] = diags
      assert d.severity == :warning
    end

    test "allows short files (well under threshold)", %{tmp_dir: tmp_dir} do
      {path, ast} = write_module(tmp_dir, "short_module", 50)
      assert [] = ModuleLength.analyze(path, ast, [])
    end
  end
end
