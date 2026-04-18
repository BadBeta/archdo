defmodule Archdo.Rules.Module.BangInOkErrorFunctionTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.BangInOkErrorFunction

  describe "analyze/3" do
    test "flags ok/error function calling bang" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create_user(attrs) do
          user = MyApp.Repo.insert!(MyApp.User.changeset(%MyApp.User{}, attrs))
          {:ok, user}
        end
      end
      """

      diags = assert_flagged(BangInOkErrorFunction, code)
      assert hd(diags).rule_id == "6.15"
      assert hd(diags).message =~ "bang"
    end

    test "allows ok/error function using non-bang calls" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create_user(attrs) do
          case MyApp.Repo.insert(MyApp.User.changeset(%MyApp.User{}, attrs)) do
            {:ok, user} -> {:ok, user}
            {:error, changeset} -> {:error, changeset}
          end
        end
      end
      """

      assert_clean(BangInOkErrorFunction, code)
    end

    test "allows bang function calling other bangs" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def create_user!(attrs) do
          MyApp.Repo.insert!(MyApp.User.changeset(%MyApp.User{}, attrs))
        end
      end
      """

      assert_clean(BangInOkErrorFunction, code)
    end

    test "allows init/start_link with bangs" do
      code = ~S"""
      defmodule MyApp.Worker do
        use GenServer

        def start_link(opts) do
          config = Keyword.fetch!(opts, :config)
          GenServer.start_link(__MODULE__, config)
        end

        def init(config) do
          table = :ets.new(:cache, [:named_table])
          {:ok, %{table: table, config: config}}
        end
      end
      """

      assert_clean(BangInOkErrorFunction, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        def create_user(attrs) do
          user = MyApp.Repo.insert!(MyApp.User.changeset(%MyApp.User{}, attrs))
          {:ok, user}
        end
      end
      """

      assert_clean(BangInOkErrorFunction, code, file: "test/accounts_test.exs")
    end
  end
end
