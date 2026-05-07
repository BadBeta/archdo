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

    @tag :tmp_dir
    test "skips files under benches/ — Criterion benchmarks aren't NIF code", %{tmp_dir: tmp_dir} do
      bench_dir = Path.join(tmp_dir, "benches")
      File.mkdir_p!(bench_dir)
      rs_file = Path.join(bench_dir, "render.rs")

      File.write!(rs_file, """
      use criterion::Criterion;

      fn bench_render(c: &mut Criterion) {
          let img = load_image("test.png").unwrap();
          let result = render(&img).expect("render failed");
          c.bench_function("render", |b| b.iter(|| render(&img)));
      }
      """)

      diags = NifPanic.analyze_rust_file(rs_file)
      assert diags == []
    end

    @tag :tmp_dir
    test "skips files under src/bin/ — standalone binaries aren't NIFs", %{tmp_dir: tmp_dir} do
      bin_dir = Path.join([tmp_dir, "src", "bin"])
      File.mkdir_p!(bin_dir)
      rs_file = Path.join(bin_dir, "host.rs")

      File.write!(rs_file, """
      fn main() {
          let port = std::env::var("PORT").expect("PORT not set");
          println!("listening on {}", port);
      }
      """)

      diags = NifPanic.analyze_rust_file(rs_file)
      assert diags == []
    end

    @tag :tmp_dir
    test "skips files under examples/ — example programs aren't NIFs", %{tmp_dir: tmp_dir} do
      ex_dir = Path.join(tmp_dir, "examples")
      File.mkdir_p!(ex_dir)
      rs_file = Path.join(ex_dir, "demo.rs")

      File.write!(rs_file, """
      fn main() {
          let result = compute().unwrap();
          println!("{}", result);
      }
      """)

      diags = NifPanic.analyze_rust_file(rs_file)
      assert diags == []
    end

    @tag :tmp_dir
    test "STILL flags unwrap in true NIF source (regression guard)", %{tmp_dir: tmp_dir} do
      src_dir = Path.join(tmp_dir, "src")
      File.mkdir_p!(src_dir)
      rs_file = Path.join(src_dir, "lib.rs")

      File.write!(rs_file, """
      use rustler::NifResult;

      #[rustler::nif]
      fn process(input: String) -> NifResult<String> {
          Ok(do_work(&input).unwrap())
      }
      """)

      diags = NifPanic.analyze_rust_file(rs_file)
      assert length(diags) >= 1
      assert hd(diags).rule_id == "11.3"
    end
  end
end
