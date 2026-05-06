defmodule Archdo.Rules.Module.EncoderWithoutDecoderTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.EncoderWithoutDecoder

  describe "encoder without decoder" do
    test "flags `to_xml/1` with no `from_xml`/`parse_xml`/`decode_xml`" do
      code = ~S"""
      defmodule MyApp.Document do
        defstruct [:body]

        def to_xml(%__MODULE__{body: b}), do: "<doc>#{b}</doc>"
      end
      """

      [diag] = assert_flagged(EncoderWithoutDecoder, code)
      assert diag.rule_id == "6.102"
      assert diag.severity == :info
      assert diag.message =~ "to_xml"
    end

    test "flags `to_proto/1` with no decoder" do
      code = ~S"""
      defmodule MyApp.Message do
        def to_proto(msg), do: Protobuf.encode(msg)
      end
      """

      [diag] = assert_flagged(EncoderWithoutDecoder, code)
      assert diag.message =~ "to_proto"
    end

    test "flags `to_csv/1` with no decoder" do
      code = ~S"""
      defmodule MyApp.Record do
        def to_csv(r), do: "#{r.id},#{r.name}"
      end
      """

      [_diag] = assert_flagged(EncoderWithoutDecoder, code)
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

  describe "FP filters — external-API / lossy / stdlib" do
    test "does not flag `to_stripe/1` (external-API serializer)" do
      code = ~S"""
      defmodule MyApp.Payment do
        def to_stripe(payment), do: %{amount: payment.amount, currency: "usd"}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_minor_units/1` (lossy projection)" do
      code = ~S"""
      defmodule MyApp.Money do
        def to_minor_units(money), do: round(money.amount * 100)
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_date!/1` (stdlib wrapper)" do
      code = ~S"""
      defmodule MyApp.Util do
        def to_date!(s), do: Date.from_iso8601!(s)
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end
  end
end
