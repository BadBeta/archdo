defmodule Archdo.StatsTest do
  use ExUnit.Case, async: true

  alias Archdo.Stats

  @moduletag :tmp_dir

  defp write(tmp_dir, name, code) do
    path = Path.join(tmp_dir, name)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, code)
    path
  end

  describe "collect/1 — analyze_ast counters via the public API" do
    test "counts modules, public functions, private functions, macros", %{tmp_dir: tmp_dir} do
      write(tmp_dir, "lib/sample.ex", ~S"""
      defmodule MyApp.Sample do
        def pub_one(x), do: x
        def pub_two(x, y), do: x + y
        defp priv_one(x), do: x * 2
        defmacro macro_one(x), do: x
        defmacrop macro_priv(x), do: x
      end
      """)

      stats = Stats.collect([tmp_dir])
      assert stats.lib.modules == 1
      assert stats.lib.public_fns == 2
      assert stats.lib.private_fns == 1
      assert stats.lib.macros == 2
    end

    test "counts tests and describes from test files", %{tmp_dir: tmp_dir} do
      write(tmp_dir, "test/sample_test.exs", ~S"""
      defmodule MyApp.SampleTest do
        use ExUnit.Case
        describe "feature A" do
          test "works", do: assert true
          test "also works", do: assert true
        end
      end
      """)

      stats = Stats.collect([tmp_dir])
      assert stats.test.tests == 2
      assert stats.test.describes == 1
    end

    test "counts GenServers, Supervisors, schemas", %{tmp_dir: tmp_dir} do
      write(tmp_dir, "lib/server.ex", ~S"""
      defmodule MyApp.Server do
        use GenServer
        def init(_), do: {:ok, %{}}
      end
      """)

      write(tmp_dir, "lib/sup.ex", ~S"""
      defmodule MyApp.Sup do
        use Supervisor
        def init(_), do: {:ok, []}
      end
      """)

      write(tmp_dir, "lib/schema.ex", ~S"""
      defmodule MyApp.Schema do
        use Ecto.Schema
        schema "things" do
          field :name, :string
        end
      end
      """)

      stats = Stats.collect([tmp_dir])
      assert stats.lib.genservers == 1
      assert stats.lib.supervisors == 1
      assert stats.lib.schemas >= 1
    end

    test "counts structs, protocols, behaviours_defined and behaviours_implemented",
         %{tmp_dir: tmp_dir} do
      write(tmp_dir, "lib/proto.ex", ~S"""
      defprotocol MyApp.Proto do
        def call(x)
      end
      """)

      write(tmp_dir, "lib/behav.ex", ~S"""
      defmodule MyApp.Behav do
        @callback do_thing() :: :ok
      end
      """)

      write(tmp_dir, "lib/impl.ex", ~S"""
      defmodule MyApp.Impl do
        @behaviour MyApp.Behav
        defstruct [:value]
      end
      """)

      stats = Stats.collect([tmp_dir])
      assert stats.lib.protocols == 1
      assert stats.lib.behaviours_defined == 1
      assert stats.lib.behaviours_implemented == 1
      assert stats.lib.structs == 1
    end

    test "counts moduledocs, but not @moduledoc false", %{tmp_dir: tmp_dir} do
      write(tmp_dir, "lib/with_doc.ex", ~S"""
      defmodule MyApp.WithDoc do
        @moduledoc "hello"
      end
      """)

      write(tmp_dir, "lib/no_doc.ex", ~S"""
      defmodule MyApp.NoDoc do
        @moduledoc false
      end
      """)

      stats = Stats.collect([tmp_dir])
      assert stats.lib.modules == 2
      assert stats.lib.moduledocs == 1
    end

    test "counts @spec attributes", %{tmp_dir: tmp_dir} do
      write(tmp_dir, "lib/spec_sample.ex", ~S"""
      defmodule MyApp.Specced do
        @spec one(integer()) :: integer()
        def one(x), do: x

        @spec two(integer(), integer()) :: integer()
        def two(x, y), do: x + y

        def unspecced(x), do: x
      end
      """)

      stats = Stats.collect([tmp_dir])
      assert stats.lib.specs == 2
    end
  end
end
