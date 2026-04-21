defmodule Archdo.Rules.OTP.CallbackSprawlTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.CallbackSprawl

  describe "analyze/3" do
    test "flags GenServer with more than 10 distinct message patterns" do
      # Generate 12 distinct handle_call clauses
      clauses =
        Enum.map_join(1..12, "\n", fn i ->
          "  def handle_call(:msg_#{i}, _from, state), do: {:reply, :ok, state}"
        end)

      code = """
      defmodule MyApp.BigServer do
        use GenServer

      #{clauses}
      end
      """

      diags = assert_flagged(CallbackSprawl, code)
      assert length(diags) == 1
      assert hd(diags).rule_id == "5.43"
      assert hd(diags).severity == :warning
    end

    test "allows GenServer with 10 or fewer distinct message patterns" do
      clauses =
        Enum.map_join(1..5, "\n", fn i ->
          "  def handle_call(:msg_#{i}, _from, state), do: {:reply, :ok, state}"
        end)

      code = """
      defmodule MyApp.SmallServer do
        use GenServer

      #{clauses}
      end
      """

      assert_clean(CallbackSprawl, code)
    end

    test "counts across handle_call, handle_cast, and handle_info" do
      code = ~S"""
      defmodule MyApp.MixedServer do
        use GenServer

        def handle_call(:get, _from, state), do: {:reply, state, state}
        def handle_call(:set, _from, state), do: {:reply, :ok, state}
        def handle_call(:delete, _from, state), do: {:reply, :ok, state}
        def handle_call(:list, _from, state), do: {:reply, state, state}

        def handle_cast(:reset, state), do: {:noreply, %{}}
        def handle_cast(:sync, state), do: {:noreply, state}
        def handle_cast(:flush, state), do: {:noreply, state}
        def handle_cast(:compact, state), do: {:noreply, state}

        def handle_info(:timeout, state), do: {:noreply, state}
        def handle_info(:refresh, state), do: {:noreply, state}
        def handle_info(:ping, state), do: {:noreply, state}
      end
      """

      diags = assert_flagged(CallbackSprawl, code)
      assert hd(diags).rule_id == "5.43"
    end

    test "skips non-GenServer modules" do
      code = ~S"""
      defmodule MyApp.PlainModule do
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """

      assert_clean(CallbackSprawl, code)
    end

    test "skips test files" do
      clauses =
        Enum.map_join(1..12, "\n", fn i ->
          "  def handle_call(:msg_#{i}, _from, state), do: {:reply, :ok, state}"
        end)

      code = """
      defmodule MyApp.BigServerTest do
        use GenServer

      #{clauses}
      end
      """

      assert_clean(CallbackSprawl, code, file: "test/my_app/big_server_test.exs")
    end
  end
end
