defmodule Archdo.Rules.OTP.SensitiveStateNoFormatStatusTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.SensitiveStateNoFormatStatus

  test "fires on GenServer with `:api_key` field in state and no format_status/1,2" do
    code = ~S"""
    defmodule MyApp.Client do
      use GenServer

      defstruct [:api_key, :host, :timeout]

      @impl true
      def init(opts) do
        {:ok, %__MODULE__{api_key: opts[:api_key], host: opts[:host], timeout: 5_000}}
      end
    end
    """

    diags = assert_flagged(SensitiveStateNoFormatStatus, code)
    assert hd(diags).rule_id == "5.63"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "format_status"
  end

  test "does NOT fire when format_status/1 is defined" do
    code = ~S"""
    defmodule MyApp.Client do
      use GenServer

      defstruct [:api_key, :host]

      @impl true
      def init(opts), do: {:ok, %__MODULE__{api_key: opts[:api_key], host: opts[:host]}}

      @impl true
      def format_status(_reason, [_pdict, state]) do
        [data: [{~c"State", %{state | api_key: "[REDACTED]"}}]]
      end
    end
    """

    assert_clean(SensitiveStateNoFormatStatus, code)
  end

  test "does NOT fire on GenServer state without sensitive-named fields" do
    code = ~S"""
    defmodule MyApp.Counter do
      use GenServer

      defstruct [:count, :max]

      @impl true
      def init(_), do: {:ok, %__MODULE__{count: 0, max: 100}}
    end
    """

    assert_clean(SensitiveStateNoFormatStatus, code)
  end
end
