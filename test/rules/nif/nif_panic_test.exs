defmodule Archdo.Rules.NIF.NifPanicTest do
  use Archdo.RuleCase

  alias Archdo.Rules.NIF.NifPanic

  describe "analyze_rust_file/1" do
    @tag :tmp_dir
    test "flags unwrap in Rust NIF code", %{tmp_dir: tmp_dir} do
      rs_file = Path.join(tmp_dir, "lib.rs")

      File.write!(rs_file, """
      use rustler::NifResult;

      fn process(input: Binary) -> NifResult<String> {
          let result = some_fn().unwrap();
          Ok(result)
      }
      """)

      diags = NifPanic.analyze_rust_file(rs_file)
      assert [diag] = diags
      assert diag.rule_id == "11.3"
      assert diag.message =~ "unwrap"
    end

    @tag :tmp_dir
    test "allows safe Rust code", %{tmp_dir: tmp_dir} do
      rs_file = Path.join(tmp_dir, "lib.rs")

      File.write!(rs_file, """
      use rustler::NifResult;

      fn process(input: Binary) -> NifResult<String> {
          let result = some_fn()?;
          Ok(result)
      }
      """)

      diags = NifPanic.analyze_rust_file(rs_file)
      assert diags == []
    end

    @tag :tmp_dir
    test "skips unwrap inside #[cfg(test)] blocks", %{tmp_dir: tmp_dir} do
      rs_file = Path.join(tmp_dir, "lib.rs")

      File.write!(rs_file, """
      fn safe_fn() -> Result<(), String> {
          Ok(())
      }

      #[cfg(test)]
      mod tests {
          fn test_helper() {
              safe_fn().unwrap();
          }
      }
      """)

      diags = NifPanic.analyze_rust_file(rs_file)
      assert diags == []
    end
  end
end
