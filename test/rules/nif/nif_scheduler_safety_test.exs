defmodule Archdo.Rules.NIF.NifSchedulerSafetyTest do
  use Archdo.RuleCase

  alias Archdo.Rules.NIF.NifSchedulerSafety

  describe "analyze/3" do
    test "flags NIF module with stubs but no dirty scheduler config" do
      code = ~S"""
      defmodule MyApp.Native.Compress do
        use Rustler, otp_app: :my_app

        def compress(_data), do: raise "NIF not loaded"
        def decompress(_data), do: raise "NIF not loaded"
      end
      """

      diags = assert_flagged(NifSchedulerSafety, code)
      assert hd(diags).rule_id == "11.2"
    end

    test "ignores non-NIF modules" do
      code = ~S"""
      defmodule MyApp.Compressor do
        def compress(data), do: :zlib.compress(data)
      end
      """

      assert_clean(NifSchedulerSafety, code)
    end
  end
end
