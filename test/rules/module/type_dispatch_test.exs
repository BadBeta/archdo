defmodule Archdo.Rules.Module.TypeDispatchTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.TypeDispatch

  test "flags case with many atom dispatch branches" do
    code = ~S"""
    defmodule MyApp.Notifier do
      def notify(type, msg) do
        case type do
          :email -> send_email(msg)
          :sms -> send_sms(msg)
          :push -> send_push(msg)
          :slack -> send_slack(msg)
          :webhook -> send_webhook(msg)
        end
      end
    end
    """

    diags = assert_flagged(TypeDispatch, code)
    assert hd(diags).message =~ "type atoms"
  end

  test "allows small case with 2-3 branches" do
    code = ~S"""
    defmodule MyApp.Parser do
      def parse(format, data) do
        case format do
          :json -> Jason.decode(data)
          :csv -> parse_csv(data)
        end
      end
    end
    """

    assert_clean(TypeDispatch, code)
  end

  test "allows ok/error pattern matching" do
    code = ~S"""
    defmodule MyApp.Handler do
      def handle(result) do
        case result do
          {:ok, data} -> process(data)
          {:error, reason} -> log(reason)
        end
      end
    end
    """

    assert_clean(TypeDispatch, code)
  end

  test "flags multi-clause function dispatching on 4+ atom types" do
    code = ~S"""
    defmodule MyApp.Processor do
      def process(:csv, data), do: parse_csv(data)
      def process(:json, data), do: parse_json(data)
      def process(:xml, data), do: parse_xml(data)
      def process(:yaml, data), do: parse_yaml(data)
      def process(:toml, data), do: parse_toml(data)
    end
    """

    diags = assert_flagged(TypeDispatch, code)
    assert hd(diags).title =~ "Multi-clause"
    assert hd(diags).message =~ "5 clauses"
  end

  test "allows multi-clause function with fewer than 4 atom types" do
    code = ~S"""
    defmodule MyApp.Formatter do
      def format(:json, data), do: Jason.encode!(data)
      def format(:text, data), do: to_string(data)
    end
    """

    assert_clean(TypeDispatch, code)
  end

  test "ignores ok/error in multi-clause dispatch" do
    code = ~S"""
    defmodule MyApp.Handler do
      def handle(:ok, data), do: success(data)
      def handle(:error, reason), do: failure(reason)
      def handle(nil, _), do: :noop
    end
    """

    assert_clean(TypeDispatch, code)
  end
end
