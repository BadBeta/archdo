defmodule Archdo.Rules.Module.ModuleLengthTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ModuleLength

  describe "analyze/3" do
    @describetag :tmp_dir

    test "flags files over 500 lines", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "long_module.ex")

      content =
        ["defmodule MyApp.LongModule do"] ++
          Enum.map(1..550, fn i -> "  def func_#{i}, do: #{i}" end) ++
          ["end"]

      File.write!(path, Enum.join(content, "\n"))

      {:ok, ast} =
        Code.string_to_quoted(
          File.read!(path),
          file: path,
          columns: true,
          token_metadata: true
        )

      diags = ModuleLength.analyze(path, ast, [])
      assert length(diags) > 0
      assert hd(diags).rule_id == "6.4"
    end

    test "allows files under 500 lines", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "short_module.ex")

      content =
        ["defmodule MyApp.ShortModule do"] ++
          Enum.map(1..50, fn i -> "  def func_#{i}, do: #{i}" end) ++
          ["end"]

      File.write!(path, Enum.join(content, "\n"))

      {:ok, ast} =
        Code.string_to_quoted(
          File.read!(path),
          file: path,
          columns: true,
          token_metadata: true
        )

      diags = ModuleLength.analyze(path, ast, [])
      assert diags == []
    end
  end
end
