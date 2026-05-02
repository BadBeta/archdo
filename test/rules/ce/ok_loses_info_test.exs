defmodule Archdo.Rules.CE.OkLosesInfoTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.OkLosesInfo

  test "fires when last expression returns {:ok, value} but function returns :ok" do
    code = ~S"""
    defmodule MyApp.Accounts do
      def create_user(attrs) do
        {:ok, _user} = Repo.insert(%User{} |> User.changeset(attrs))
        :ok
      end
    end
    """

    diags = assert_flagged(OkLosesInfo, code)
    assert hd(diags).rule_id == "CE-50"
    assert hd(diags).severity == :warning
    assert hd(diags).message =~ "create_user"
  end

  test "does NOT fire when function returns the {:ok, value} tuple" do
    code = ~S"""
    defmodule MyApp.Accounts do
      def create_user(attrs), do: Repo.insert(%User{} |> User.changeset(attrs))
    end
    """

    assert_clean(OkLosesInfo, code)
  end

  test "does NOT fire when @archdo_fire_and_forget marker is present" do
    code = ~S"""
    defmodule MyApp.Cache do
      @archdo_fire_and_forget true
      def invalidate(key) do
        :ets.delete(:my_cache, key)
        :ok
      end
    end
    """

    assert_clean(OkLosesInfo, code)
  end

  test "does NOT fire when the function does no meaningful work" do
    # Trivial functions returning :ok with no preceding richer-result
    # call are pure side-effect or no-op; nothing to lose.
    code = ~S"""
    defmodule MyApp.Noop do
      def ping, do: :ok
    end
    """

    assert_clean(OkLosesInfo, code)
  end

  describe "M-Aux2 — broadened detection" do
    test "fires on bang-call discarded result followed by :ok" do
      # Repo.insert! returns the inserted struct; throwing it away to
      # return bare :ok loses information.
      code = ~S"""
      defmodule MyApp.Accounts do
        def save(attrs) do
          Repo.insert!(%User{} |> User.changeset(attrs))
          :ok
        end
      end
      """

      diags = assert_flagged(OkLosesInfo, code)
      assert hd(diags).rule_id == "CE-50"
    end

    test "fires when richer result is bound but never used downstream" do
      # `result = X.fetch()` where `result` doesn't appear anywhere else
      # before the function returns :ok.
      code = ~S"""
      defmodule MyApp.Service do
        def go(id) do
          result = Repo.get(Order, id)
          :ok
        end
      end
      """

      diags = assert_flagged(OkLosesInfo, code)
      assert hd(diags).rule_id == "CE-50"
    end

    test "M-Plan9 v2: fires when bound result IS used in a subsequent leaf call" do
      # `result = X.fetch(); process(result); :ok` — the value flowed
      # through one call but the function returns :ok literal. The
      # chain doesn't escape to the return position; the richer
      # value is still discarded. v2 (M-Plan9) detects this.
      code = ~S"""
      defmodule MyApp.Service do
        def go(id) do
          result = Repo.get(Order, id)
          process(result)
          :ok
        end
      end
      """

      diags = assert_flagged(OkLosesInfo, code)
      assert hd(diags).rule_id == "CE-50"
    end

    test "M-Plan9: does NOT fire when chain terminates in {:ok, derived}" do
      # `result = X.fetch(); processed = process(result); {:ok, processed}`
      # — the derived value escapes via the return, so the richer
      # result IS preserved (transformed but preserved). No firing.
      code = ~S"""
      defmodule MyApp.Service do
        def go(id) do
          result = Repo.get(Order, id)
          processed = process(result)
          {:ok, processed}
        end
      end
      """

      assert_clean(OkLosesInfo, code)
    end

    test "fires on Mailer.deliver discarded then :ok" do
      code = ~S"""
      defmodule MyApp.Notify do
        def send_welcome(user) do
          Mailer.deliver(WelcomeEmail.build(user))
          :ok
        end
      end
      """

      diags = assert_flagged(OkLosesInfo, code)
      assert hd(diags).rule_id == "CE-50"
    end

    test "does NOT fire on bang-call that genuinely returns :ok" do
      # Some bangs are :ok-returning (Logger.info!, etc.). v1 only
      # treats Repo / Mailer / HTTP-client bangs as richer-result.
      code = ~S"""
      defmodule MyApp.Util do
        def go(msg) do
          Logger.info(msg)
          :ok
        end
      end
      """

      assert_clean(OkLosesInfo, code)
    end
  end
end
