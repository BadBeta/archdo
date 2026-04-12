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
end
