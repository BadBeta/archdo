defmodule Archdo.Rules.Composition.PipelineSideEffectTerminatorTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Composition.PipelineSideEffectTerminator

  describe "fires when a side-effecting function does not pass its first arg through" do
    test "Logger side effect, returns :ok" do
      code = ~S"""
      defmodule MyApp.Audit do
        require Logger
        @spec record(map()) :: :ok
        def record(event) do
          Logger.info("audit: #{inspect(event)}")
          :ok
        end
      end
      """

      diags = assert_flagged(PipelineSideEffectTerminator, code)
      assert hd(diags).rule_id == "10.4"
      assert hd(diags).severity == :info
      assert hd(diags).message =~ "record"
    end

    test "Repo WRITE (insert) returning nil does fire" do
      code = ~S"""
      defmodule MyApp.Saver do
        @spec persist(map()) :: nil
        def persist(record) do
          Repo.insert(record)
          nil
        end
      end
      """

      diags = assert_flagged(PipelineSideEffectTerminator, code)
      assert hd(diags).rule_id == "10.4"
    end

    test "IO.puts side effect does fire" do
      code = ~S"""
      defmodule MyApp.Print do
        @spec announce(String.t()) :: :ok
        def announce(message) do
          IO.puts(message)
          :ok
        end
      end
      """

      diags = assert_flagged(PipelineSideEffectTerminator, code)
      assert hd(diags).rule_id == "10.4"
    end

    test "File.write side effect does fire" do
      code = ~S"""
      defmodule MyApp.Files do
        @spec save(String.t()) :: :ok
        def save(content) do
          File.write("/tmp/x", content)
          :ok
        end
      end
      """

      diags = assert_flagged(PipelineSideEffectTerminator, code)
      assert hd(diags).rule_id == "10.4"
    end

    test "telemetry side effect, returns atom" do
      code = ~S"""
      defmodule MyApp.Tele do
        @spec mark(map()) :: :marked
        def mark(measurement) do
          :telemetry.execute([:my_app, :event], measurement)
          :marked
        end
      end
      """

      diags = assert_flagged(PipelineSideEffectTerminator, code)
      assert hd(diags).rule_id == "10.4"
    end
  end

  describe "does NOT fire" do
    test "Repo READ (get_by) does not fire — criteria, not subject" do
      # `find_user_by(opts) :: User.t() | nil` is a query: opts is
      # criteria, not the pipeline subject. The function transforms
      # criteria into an entity; that's not a side-effect terminator.
      code = ~S"""
      defmodule MyApp.Accounts do
        @spec find_user_by(Keyword.t()) :: User.t() | nil
        def find_user_by(opts) do
          Repo.get_by(User, opts)
        end
      end
      """

      assert_clean(PipelineSideEffectTerminator, code)
    end

    test "constructor returning {:ok, U} where U ≠ first-arg type does not fire" do
      # `create_session(user, name) :: {:ok, Session.t()} | {:error, _}`
      # is a constructor: the user is context, the session is the new
      # entity. The pipeline composes by piping the RESULT through
      # `with` — not by piping the user through.
      code = ~S"""
      defmodule MyApp.Accounts do
        @spec create_session(User.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
        def create_session(user, name) do
          Repo.insert(%Session{user_id: user.id, name: name})
        end
      end
      """

      assert_clean(PipelineSideEffectTerminator, code)
    end

    test "Repo READ (all) does not fire" do
      code = ~S"""
      defmodule MyApp.Accounts do
        @spec list_users(Keyword.t()) :: [User.t()]
        def list_users(opts) do
          Repo.all(from u in User, where: u.active == ^opts[:active])
        end
      end
      """

      assert_clean(PipelineSideEffectTerminator, code)
    end

    test "function returns its first arg after the side effect" do
      code = ~S"""
      defmodule MyApp.Audit do
        require Logger
        @spec record(map()) :: map()
        def record(event) do
          Logger.info("audit: #{inspect(event)}")
          event
        end
      end
      """

      assert_clean(PipelineSideEffectTerminator, code)
    end

    test "function has no @spec" do
      code = ~S"""
      defmodule MyApp.Audit do
        require Logger
        def record(event) do
          Logger.info("audit: #{inspect(event)}")
          :ok
        end
      end
      """

      assert_clean(PipelineSideEffectTerminator, code)
    end

    test "function performs no known side effect" do
      code = ~S"""
      defmodule MyApp.Pure do
        @spec count(list()) :: non_neg_integer()
        def count(list), do: length(list)
      end
      """

      assert_clean(PipelineSideEffectTerminator, code)
    end

    test "function returns {:ok, T} where T is the input type" do
      code = ~S"""
      defmodule MyApp.Save do
        @spec save(map()) :: {:ok, map()} | {:error, term()}
        def save(record) do
          Repo.insert(record)
          {:ok, record}
        end
      end
      """

      assert_clean(PipelineSideEffectTerminator, code)
    end

    test "function is private" do
      code = ~S"""
      defmodule MyApp.Audit do
        require Logger
        @spec record(map()) :: :ok
        defp record(event) do
          Logger.info("audit: #{inspect(event)}")
          :ok
        end
      end
      """

      assert_clean(PipelineSideEffectTerminator, code)
    end

    test "test files are skipped" do
      code = ~S"""
      defmodule MyApp.AuditTest do
        require Logger
        @spec record(map()) :: :ok
        def record(event) do
          Logger.info("audit: #{inspect(event)}")
          :ok
        end
      end
      """

      assert_clean(PipelineSideEffectTerminator, code, file: "test/my_app/audit_test.exs")
    end

    test "function takes no arguments (no input to pass through)" do
      code = ~S"""
      defmodule MyApp.Heartbeat do
        require Logger
        @spec ping() :: :ok
        def ping do
          Logger.info("ping")
          :ok
        end
      end
      """

      assert_clean(PipelineSideEffectTerminator, code)
    end

    test "function has no first parameter type spec we can match" do
      code = ~S"""
      defmodule MyApp.Untyped do
        require Logger
        @spec record(any()) :: :ok
        def record(event) do
          Logger.info("audit: #{inspect(event)}")
          :ok
        end
      end
      """

      # any() return doesn't claim a specific shape — but here we'd treat
      # any() input as too unconstrained to be confident the function
      # should pipe-through. Skip to avoid false positives.
      assert_clean(PipelineSideEffectTerminator, code)
    end
  end
end
