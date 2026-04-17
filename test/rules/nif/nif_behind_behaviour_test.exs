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
end
