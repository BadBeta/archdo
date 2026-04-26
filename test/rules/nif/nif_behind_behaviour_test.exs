defmodule Archdo.Rules.NIF.NifBehindBehaviourTest do
  use Archdo.RuleCase

  alias Archdo.Rules.NIF.NifBehindBehaviour

  describe "analyze/3" do
    test "flags NIF module without behaviour" do
      code = ~S"""
      defmodule MyApp.Native.Hasher do
        use Rustler, otp_app: :my_app

        def hash(_input), do: :erlang.nif_error(:not_loaded)
      end
      """

      diags = assert_flagged(NifBehindBehaviour, code)
      assert hd(diags).rule_id == "11.1"
    end

    test "allows NIF module that implements a behaviour" do
      code = ~S"""
      defmodule MyApp.Native.Hasher do
        use Rustler, otp_app: :my_app
        @behaviour MyApp.Hasher

        @impl true
        def hash(_input), do: :erlang.nif_error(:not_loaded)
      end
      """

      assert_clean(NifBehindBehaviour, code)
    end

    test "ignores non-NIF modules" do
      code = ~S"""
      defmodule MyApp.RegularModule do
        def hello, do: :world
      end
      """

      assert_clean(NifBehindBehaviour, code)
    end
  end

  describe "Shape A: wrapper + @moduledoc false stub on disk" do
    setup do
      root = Path.join(System.tmp_dir!(), "archdo_nbb_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(Path.join(root, "lib/relix_array"))
      File.write!(Path.join(root, "mix.exs"), ~s|defmodule Foo.MixProject do
  use Mix.Project
  def project, do: [app: :foo, version: "0.1.0"]
end|)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "skips internal NIF stub when sibling wrapper file exists", %{root: root} do
      File.write!(
        Path.join(root, "lib/relix_array.ex"),
        "defmodule RelixArray do\n  @moduledoc \"public api\"\n  def x, do: RelixArray.Native.x()\nend"
      )

      stub = ~S"""
      defmodule RelixArray.Native do
        @moduledoc false
        use Rustler, otp_app: :relix_array

        def x, do: :erlang.nif_error(:nif_not_loaded)
      end
      """

      File.write!(Path.join(root, "lib/relix_array/native.ex"), stub)

      assert_clean(NifBehindBehaviour, stub, file: Path.join(root, "lib/relix_array/native.ex"))
    end

    test "still flags internal NIF stub when no wrapper exists", %{root: root} do
      stub = ~S"""
      defmodule RelixArray.Native do
        @moduledoc false
        use Rustler, otp_app: :relix_array

        def x, do: :erlang.nif_error(:nif_not_loaded)
      end
      """

      File.write!(Path.join(root, "lib/relix_array/native.ex"), stub)

      diags =
        assert_flagged(NifBehindBehaviour, stub,
          file: Path.join(root, "lib/relix_array/native.ex")
        )

      assert hd(diags).rule_id == "11.1"
    end

    test "still flags non-internal NIF (no @moduledoc false) even with wrapper", %{root: root} do
      File.write!(
        Path.join(root, "lib/relix_array.ex"),
        "defmodule RelixArray do\n  def x, do: :ok\nend"
      )

      stub = ~S"""
      defmodule RelixArray.Native do
        use Rustler, otp_app: :relix_array

        def x, do: :erlang.nif_error(:nif_not_loaded)
      end
      """

      File.write!(Path.join(root, "lib/relix_array/native.ex"), stub)

      diags =
        assert_flagged(NifBehindBehaviour, stub,
          file: Path.join(root, "lib/relix_array/native.ex")
        )

      assert hd(diags).rule_id == "11.1"
    end
  end
end
