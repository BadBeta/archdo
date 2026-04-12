defmodule Archdo.Rules.OTP.BlockingInitTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.BlockingInit

  test "flags HTTP call in init" do
    code = ~S"""
    defmodule MyApp.ConfigLoader do
      use GenServer

      def init(args) do
        data = Req.get!("https://api.example.com/config")
        {:ok, %{data: data}}
      end
    end
    """

    diags = assert_flagged(BlockingInit, code)
    diag = hd(diags)
    assert diag.severity == :warning
    assert diag.rule_id == "5.8"
    assert diag.title == "Blocking work in GenServer init/1"
    assert diag.message =~ "Req.get!"
    assert diag.context.call =~ "Req"
  end

  test "flags Repo call in init" do
    code = ~S"""
    defmodule MyApp.CacheLoader do
      use GenServer

      def init(_) do
        items = MyApp.Repo.all(MyApp.Item)
        {:ok, %{items: items}}
      end
    end
    """

    diags = assert_flagged(BlockingInit, code)
    assert hd(diags).message =~ "Repo"
  end

  test "flags Process.sleep in init" do
    code = ~S"""
    defmodule MyApp.Server do
      use GenServer

      def init(_) do
        Process.sleep(1000)
        {:ok, %{}}
      end
    end
    """

    assert_flagged(BlockingInit, code)
  end

  test "allows handle_continue pattern" do
    code = ~S"""
    defmodule MyApp.ConfigLoader do
      use GenServer

      def init(args) do
        {:ok, %{data: nil}, {:continue, :load}}
      end

      def handle_continue(:load, state) do
        data = Req.get!("https://api.example.com/config")
        {:noreply, %{state | data: data}}
      end
    end
    """

    assert_clean(BlockingInit, code)
  end

  test "ignores non-GenServer modules" do
    code = ~S"""
    defmodule MyApp.Setup do
      def init(args) do
        Req.get!("https://api.example.com")
      end
    end
    """

    assert_clean(BlockingInit, code)
  end
end
