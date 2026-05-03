defmodule Archdo.Rules.Module.IoInspectInLibTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.IoInspectInLib

  describe "analyze/3 — IO.inspect" do
    test "flags IO.inspect/1 in lib/" do
      code = ~S"""
      defmodule MyApp.Worker do
        def run(input) do
          IO.inspect(input)
          process(input)
        end
      end
      """

      diags = assert_flagged(IoInspectInLib, code, file: "lib/my_app/worker.ex")
      diag = hd(diags)
      assert diag.severity == :warning
      assert diag.title =~ "IO.inspect"
    end

    test "flags IO.inspect/2 with label" do
      code = ~S"""
      defmodule MyApp.Worker do
        def run(input) do
          IO.inspect(input, label: "input")
        end
      end
      """

      assert_flagged(IoInspectInLib, code, file: "lib/my_app/worker.ex")
    end

    test "flags IO.inspect inside a pipeline (final step)" do
      code = ~S"""
      defmodule MyApp.Worker do
        def run(input) do
          input |> transform() |> IO.inspect()
        end
      end
      """

      assert_flagged(IoInspectInLib, code, file: "lib/my_app/worker.ex")
    end
  end

  describe "analyze/3 — dbg" do
    test "flags dbg/1 in lib/" do
      code = ~S"""
      defmodule MyApp.Worker do
        def run(input) do
          dbg(input)
          input
        end
      end
      """

      diags = assert_flagged(IoInspectInLib, code, file: "lib/my_app/worker.ex")
      assert hd(diags).title =~ "dbg"
    end

    test "flags Kernel.dbg/1" do
      code = ~S"""
      defmodule MyApp.Worker do
        def run(input) do
          Kernel.dbg(input)
        end
      end
      """

      assert_flagged(IoInspectInLib, code, file: "lib/my_app/worker.ex")
    end

    test "flags pipe-into dbg" do
      code = ~S"""
      defmodule MyApp.Worker do
        def run(input) do
          input |> transform() |> dbg()
        end
      end
      """

      assert_flagged(IoInspectInLib, code, file: "lib/my_app/worker.ex")
    end
  end

  describe "analyze/3 — file scoping" do
    test "skips test files" do
      code = ~S"""
      defmodule MyApp.WorkerTest do
        def helper(input) do
          IO.inspect(input)
        end
      end
      """

      assert analyze(IoInspectInLib, code, file: "test/my_app/worker_test.exs") == []
    end

    test "skips priv/ paths" do
      code = ~S"""
      defmodule MyApp.MigrationHelper do
        def show(input) do
          IO.inspect(input)
        end
      end
      """

      assert analyze(IoInspectInLib, code, file: "priv/repo/migrations/seed.exs") == []
    end
  end

  describe "analyze/3 — non-debug calls allowed" do
    test "does not flag IO.puts" do
      code = ~S"""
      defmodule MyApp.Worker do
        def run(input) do
          IO.puts(input)
        end
      end
      """

      assert_clean(IoInspectInLib, code, file: "lib/my_app/worker.ex")
    end

    test "does not flag IO.write" do
      code = ~S"""
      defmodule MyApp.Worker do
        def run(input) do
          IO.write(input)
        end
      end
      """

      assert_clean(IoInspectInLib, code, file: "lib/my_app/worker.ex")
    end

    test "does not flag plain inspect/1 (not IO.inspect)" do
      code = ~S"""
      defmodule MyApp.Worker do
        def render(input) do
          msg = "got: " <> inspect(input)
          send_log(msg)
        end
      end
      """

      assert_clean(IoInspectInLib, code, file: "lib/my_app/worker.ex")
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert IoInspectInLib.id() == "5.53"
    end

    test "description mentions IO.inspect or dbg" do
      desc = IoInspectInLib.description()
      assert desc =~ "IO.inspect" or desc =~ "dbg"
    end
  end
end
