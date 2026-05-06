defmodule Archdo.Rules.Module.BuilderPatternNotThreadedTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.BuilderPatternNotThreaded

  describe "builder rebind chains" do
    test "flags 3+ Multi rebinds" do
      code = ~S"""
      defmodule MyApp.Service do
        def call do
          multi = Ecto.Multi.new()
          multi = Ecto.Multi.insert(multi, :user, %{})
          multi = Ecto.Multi.update(multi, :profile, %{})
          multi = Ecto.Multi.run(multi, :notify, fn _, _ -> {:ok, nil} end)
          MyApp.Repo.transaction(multi)
        end
      end
      """

      [diag] = assert_flagged(BuilderPatternNotThreaded, code)
      assert diag.rule_id == "6.101"
      assert diag.severity == :info
      assert diag.message =~ "multi"
    end

    test "flags 3+ socket rebinds" do
      code = ~S"""
      defmodule MyAppWeb.UserLive do
        def mount(_, _, socket) do
          socket = assign(socket, :user, nil)
          socket = assign(socket, :loading, true)
          socket = assign(socket, :error, nil)
          socket = stream(socket, :notes, [])
          {:ok, socket}
        end
      end
      """

      [diag] = assert_flagged(BuilderPatternNotThreaded, code)
      assert diag.message =~ "socket"
    end

    test "flags 3+ conn rebinds" do
      code = ~S"""
      defmodule MyAppWeb.AuthPlug do
        def call(conn, _opts) do
          conn = put_session(conn, :user_id, 1)
          conn = put_resp_header(conn, "x-user", "1")
          conn = assign(conn, :current_user, nil)
          conn
        end
      end
      """

      [diag] = assert_flagged(BuilderPatternNotThreaded, code)
      assert diag.message =~ "conn"
    end
  end

  describe "clean code" do
    test "does not flag piped-form chain" do
      code = ~S"""
      defmodule MyApp.Service do
        def call do
          Ecto.Multi.new()
          |> Ecto.Multi.insert(:user, %{})
          |> Ecto.Multi.update(:profile, %{})
          |> Ecto.Multi.run(:notify, fn _, _ -> {:ok, nil} end)
        end
      end
      """

      assert_clean(BuilderPatternNotThreaded, code)
    end

    test "does not flag 2 rebinds (under threshold)" do
      code = ~S"""
      defmodule MyApp.Service do
        def call do
          multi = Ecto.Multi.new()
          multi = Ecto.Multi.insert(multi, :user, %{})
          multi
        end
      end
      """

      assert_clean(BuilderPatternNotThreaded, code)
    end

    test "does not flag rebinds to different names" do
      code = ~S"""
      defmodule MyApp.Pipeline do
        def run(input) do
          step1 = transform_a(input)
          step2 = transform_b(step1)
          step3 = transform_c(step2)
          step3
        end
      end
      """

      assert_clean(BuilderPatternNotThreaded, code)
    end

    test "does not flag a rebind whose RHS doesn't use the var as first arg" do
      code = ~S"""
      defmodule MyApp.Wrong do
        def call do
          x = compute_a()
          x = compute_b()
          x = compute_c()
          x
        end
      end
      """

      assert_clean(BuilderPatternNotThreaded, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.ServiceTest do
        def helper do
          conn = build_conn()
          conn = put_session(conn, :u, 1)
          conn = put_resp_header(conn, "x", "y")
          conn = assign(conn, :u, nil)
          conn
        end
      end
      """

      assert_clean(BuilderPatternNotThreaded, code, file: "test/service_test.exs")
    end
  end
end
