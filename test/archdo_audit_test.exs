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

    test "context audit lists only modules with sub-namespace members", %{tmp_dir: tmp_dir} do
      # MyApp.Accounts is a real context — it has sub-modules under
      # lib/my_app/accounts/. MyApp.Backoff is a leaf module — no
      # corresponding directory. The context audit should list only
      # MyApp.Accounts, not MyApp.Backoff. (Validated against Oban
      # — every leaf module was incorrectly treated as a context with
      # the awkward "leaks: Foo" output where Foo was the module
      # itself.)
      write(tmp_dir, "lib/my_app/accounts.ex", ~S"""
      defmodule MyApp.Accounts do
        @moduledoc "Accounts context."
        @spec list :: [map()]
        def list, do: []
        @spec get(integer()) :: map() | nil
        def get(_id), do: nil
      end
      """)

      write(tmp_dir, "lib/my_app/accounts/user.ex", ~S"""
      defmodule MyApp.Accounts.User do
        @moduledoc false
        defstruct [:id, :name]
      end
      """)

      write(tmp_dir, "lib/my_app/backoff.ex", ~S"""
      defmodule MyApp.Backoff do
        @moduledoc "Stateless backoff helper."
        @spec compute(non_neg_integer()) :: non_neg_integer()
        def compute(n), do: n * 100
        @spec jitter(non_neg_integer()) :: non_neg_integer()
        def jitter(n), do: n
      end
      """)

      output = capture_io(fn -> Archdo.print_building_blocks([tmp_dir]) end)

      # Context section header reflects the count of REAL contexts
      # (MyApp.Accounts has a sub-namespace) — so 1 of 1, not 1 of 2.
      assert output =~ ~r/Building-block CONTEXTS \(\d of 1\)/
      assert output =~ "MyApp.Accounts"
      # Backoff is NOT listed in the contexts section — it's a leaf.
      refute output =~ "MyApp.Backoff — leaks"
    end
  end
end
