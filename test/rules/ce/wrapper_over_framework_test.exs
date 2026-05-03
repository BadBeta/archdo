defmodule Archdo.Rules.CE.WrapperOverFrameworkTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.WrapperOverFramework

  defp parse(code, file) do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {file, ast}
  end

  defp analyze(file_asts), do: WrapperOverFramework.analyze_project(file_asts)

  describe "fires on single-implementor wrappers over framework abstractions" do
    test "wrapper over Ecto.Repo (Sandbox-equivalent test seam) fires" do
      behaviour =
        parse(
          """
          defmodule MyApp.RepoBehaviour do
            @callback get(module(), term()) :: term() | nil
            @callback insert(struct()) :: {:ok, struct()} | {:error, term()}
          end
          """,
          "lib/my_app/repo_behaviour.ex"
        )

      impl =
        parse(
          """
          defmodule MyApp.Repo.Adapter do
            @behaviour MyApp.RepoBehaviour
            def get(schema, id), do: Ecto.Repo.get(MyApp.Repo, schema, id)
            def insert(struct), do: Ecto.Repo.insert(MyApp.Repo, struct)
          end
          """,
          "lib/my_app/repo/adapter.ex"
        )

      assert [diag] = analyze([behaviour, impl])
      assert diag.rule_id == "CE-15"
      assert diag.severity == :warning
      assert diag.message =~ "MyApp.RepoBehaviour"
      assert diag.message =~ "Ecto.Repo"
    end

    test "wrapper over Phoenix.PubSub fires" do
      behaviour =
        parse(
          """
          defmodule MyApp.PubSubAdapter do
            @callback broadcast(String.t(), term()) :: :ok
            @callback subscribe(String.t()) :: :ok
          end
          """,
          "lib/my_app/pub_sub_adapter.ex"
        )

      impl =
        parse(
          """
          defmodule MyApp.PubSubAdapter.Phoenix do
            @behaviour MyApp.PubSubAdapter
            def broadcast(t, m), do: Phoenix.PubSub.broadcast(MyApp.PubSub, t, m)
            def subscribe(t), do: Phoenix.PubSub.subscribe(MyApp.PubSub, t)
          end
          """,
          "lib/my_app/pub_sub_adapter/phoenix.ex"
        )

      assert [diag] = analyze([behaviour, impl])
      assert diag.message =~ "Phoenix.PubSub"
    end

    test "wrapper over Oban fires" do
      behaviour =
        parse(
          """
          defmodule MyApp.JobQueue do
            @callback enqueue(term()) :: {:ok, term()} | {:error, term()}
          end
          """,
          "lib/my_app/job_queue.ex"
        )

      impl =
        parse(
          """
          defmodule MyApp.JobQueue.Oban do
            @behaviour MyApp.JobQueue
            def enqueue(args), do: Oban.insert(MyApp.Worker.new(args))
          end
          """,
          "lib/my_app/job_queue/oban.ex"
        )

      assert [diag] = analyze([behaviour, impl])
      assert diag.message =~ "Oban"
    end
  end

  describe "does NOT fire" do
    test "behaviour with multiple non-test implementors (real polymorphic abstraction)" do
      behaviour =
        parse(
          """
          defmodule MyApp.Notifier do
            @callback notify(String.t()) :: :ok
          end
          """,
          "lib/my_app/notifier.ex"
        )

      slack =
        parse(
          """
          defmodule MyApp.Notifier.Slack do
            @behaviour MyApp.Notifier
            def notify(msg), do: Slack.post(msg)
          end
          """,
          "lib/my_app/notifier/slack.ex"
        )

      email =
        parse(
          """
          defmodule MyApp.Notifier.Email do
            @behaviour MyApp.Notifier
            def notify(msg), do: Bamboo.deliver(msg)
          end
          """,
          "lib/my_app/notifier/email.ex"
        )

      assert analyze([behaviour, slack, email]) == []
    end

    test "single implementor whose principal target is NOT a framework abstraction" do
      behaviour =
        parse(
          """
          defmodule MyApp.PriceCalculator do
            @callback calculate(integer(), integer()) :: integer()
          end
          """,
          "lib/my_app/price_calculator.ex"
        )

      impl =
        parse(
          """
          defmodule MyApp.PriceCalculator.Standard do
            @behaviour MyApp.PriceCalculator
            def calculate(qty, unit), do: MyApp.Math.multiply(qty, unit)
          end
          """,
          "lib/my_app/price_calculator/standard.ex"
        )

      assert analyze([behaviour, impl]) == []
    end

    test "@archdo_policy_wrapper marker exempts a wrapper that adds policy" do
      behaviour =
        parse(
          """
          defmodule MyApp.AuditedRepo do
            @callback insert(struct()) :: {:ok, struct()} | {:error, term()}
          end
          """,
          "lib/my_app/audited_repo.ex"
        )

      impl =
        parse(
          """
          defmodule MyApp.AuditedRepo.Adapter do
            @archdo_policy_wrapper "tenant scoping + audit trail per write"
            @behaviour MyApp.AuditedRepo
            def insert(s), do: Ecto.Repo.insert(MyApp.Repo, s)
          end
          """,
          "lib/my_app/audited_repo/adapter.ex"
        )

      assert analyze([behaviour, impl]) == []
    end

    test "behaviour with zero non-test implementors does NOT fire (v1 conservatism)" do
      # The 0-impl path was disabled after field testing showed it
      # over-fired on Ecto.Type behaviours and OpenTelemetry-style
      # extension-point APIs. A future tightening could re-enable it
      # behind a stronger signal (callback names overlapping a known
      # framework's exports).
      behaviour =
        parse(
          """
          defmodule MyApp.PubSubAdapter do
            @callback broadcast(String.t(), term()) :: :ok
          end
          """,
          "lib/my_app/pub_sub_adapter.ex"
        )

      test_impl =
        parse(
          """
          defmodule MyApp.PubSubAdapter.MockImpl do
            @behaviour MyApp.PubSubAdapter
            def broadcast(_, _), do: :ok
          end
          """,
          "test/support/pub_sub_mock.ex"
        )

      assert analyze([behaviour, test_impl]) == []
    end

    test "@archdo_extension_point true exempts an API behaviour with reference impl" do
      # OpenTelemetry-style API behaviour: declares the contract,
      # ships a reference SDK impl, third parties can plug in alternates.
      # The single prod impl + framework-seam target would otherwise
      # match CE-15; the marker signals "designed extension surface".
      behaviour =
        parse(
          """
          defmodule MyApp.LoggerProvider do
            @archdo_extension_point true
            @callback emit(String.t()) :: :ok
          end
          """,
          "lib/my_app/logger_provider.ex"
        )

      sdk_impl =
        parse(
          """
          defmodule MyApp.LoggerProvider.SDK do
            @behaviour MyApp.LoggerProvider
            def emit(msg), do: GenServer.cast(__MODULE__, {:emit, msg})
          end
          """,
          "lib/my_app/logger_provider/sdk.ex"
        )

      assert analyze([behaviour, sdk_impl]) == []
    end
  end
end
