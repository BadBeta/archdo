defmodule Archdo.Rules.Module.EncoderWithoutDecoderTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.EncoderWithoutDecoder

  describe "encoder without decoder" do
    test "flags `to_string/1` with no `from_string`/`parse_string`/`decode_string`" do
      code = ~S"""
      defmodule MyApp.Email do
        defstruct [:address]

        def to_string(%__MODULE__{address: a}), do: a
      end
      """

      [diag] = assert_flagged(EncoderWithoutDecoder, code)
      assert diag.rule_id == "6.102"
      assert diag.severity == :info
      assert diag.message =~ "to_string"
    end

    test "flags `to_json/1` with no decoder" do
      code = ~S"""
      defmodule MyApp.Token do
        def to_json(token), do: Jason.encode!(token)
      end
      """

      [diag] = assert_flagged(EncoderWithoutDecoder, code)
      assert diag.message =~ "to_json"
    end

    test "flags `to_url/1` with no decoder" do
      code = ~S"""
      defmodule MyApp.Resource do
        def to_url(r), do: "http://example.com/#{r.id}"
      end
      """

      [diag] = assert_flagged(EncoderWithoutDecoder, code)
    end
  end

  describe "clean code" do
    test "does not flag when from_X exists" do
      code = ~S"""
      defmodule MyApp.Email do
        def to_string(e), do: e.address
        def from_string(s), do: %{address: s}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag when parse_X exists" do
      code = ~S"""
      defmodule MyApp.Email do
        def to_string(e), do: e.address
        def parse_string(s), do: {:ok, s}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag when decode_X exists" do
      code = ~S"""
      defmodule MyApp.Token do
        def to_json(t), do: Jason.encode!(t)
        def decode_json(s), do: Jason.decode!(s)
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag arity != 1" do
      code = ~S"""
      defmodule MyApp.Lib do
        def to_iodata(a, b), do: [a, b]
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag private fn" do
      code = ~S"""
      defmodule MyApp.Lib do
        defp to_string(_), do: ""
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.LibTest do
        def to_json(t), do: Jason.encode!(t)
      end
      """

      assert_clean(EncoderWithoutDecoder, code, file: "test/lib_test.exs")
    end
  end
end
