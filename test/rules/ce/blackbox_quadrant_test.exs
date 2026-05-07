defmodule Archdo.Rules.CE.BlackboxQuadrantTest do
  use Archdo.RuleCase

  alias Archdo.Rules.CE.BlackboxQuadrant

  describe "policy cells" do
    test "{:low, :high} fires CE-54 (substantial impure function)" do
      # Substantial body (≥ 30 AST nodes) + impure (Logger), pack
      # composability defaults active in this test.
      code = ~S"""
      defmodule MyApp.Workflow do
        @spec process(map()) :: {:ok, map()} | {:error, term()}
        def process(input) do
          case validate(input) do
            {:ok, x} ->
              y = transform(x)
              z = apply_business_rules(y)
              w = format_output(z)
              Logger.info("processed", id: w.id)
              {:ok, w}
            {:error, _} = e ->
              e
          end
        end
        defp validate(_), do: {:ok, %{}}
        defp transform(x), do: x
        defp apply_business_rules(x), do: x
        defp format_output(x), do: x
      end
      """

      diags = assert_flagged(BlackboxQuadrant, code, file: "lib/my_app/workflow.ex")
      assert hd(diags).rule_id == "CE-54"
      assert hd(diags).severity == :info
    end

    test "{:high, :low} (trivial pure function) does NOT fire" do
      code = ~S"""
      defmodule MyApp.Plain do
        @spec double(integer()) :: integer()
        def double(x), do: x * 2
      end
      """

      assert_clean(BlackboxQuadrant, code, file: "lib/my_app/plain.ex")
    end

    test "{:low, :low} (orchestrator function — handle_event) does NOT fire" do
      code = ~S"""
      defmodule MyAppWeb.SomeLive do
        def handle_event("submit", params, socket) do
          Logger.info("submit", params: params)
          {:noreply, socket}
        end
      end
      """

      assert_clean(BlackboxQuadrant, code, file: "lib/my_app_web/some_live.ex")
    end

    test "{:high, :high} (substantial pure function with @spec) does NOT fire CE-54" do
      # Building-block already — no actionable finding from CE-54.
      # CE-55 (deferred to M-Aux) would mark it as a property-test
      # candidate, but CE-54 itself stays clean.
      code = ~S"""
      defmodule MyApp.Math do
        @spec compose(integer(), integer(), integer(), integer()) :: integer()
        def compose(a, b, c, d) do
          x = a + b
          y = c + d
          z = x * y
          w = z - a
          v = w + b
          u = v * c
          t = u - d
          t
        end
      end
      """

      assert_clean(BlackboxQuadrant, code, file: "lib/my_app/math.ex")
    end

    test "adapter modules (@behaviour Foo) do NOT fire — impurity is by design" do
      # Validated against real-world Oban (M-CG88): every Oban engine,
      # notifier, peer, and plugin implements a project-defined
      # @behaviour AND does substantial DB / GenServer / I/O work.
      # The whole point of those behaviours is to swap the impure
      # boundary at config time. Flagging the impurity inside an
      # adapter is the wrong layer of analysis — the behaviour IS the
      # building-block contract; the implementations are the impure
      # adapters by design.
      code = ~S"""
      defmodule MyApp.Engines.Postgres do
        @behaviour MyApp.Engine

        @impl true
        def insert_job(conf, changeset, opts) do
          row = build_row(changeset, opts)
          Logger.info("inserting", queue: row.queue, args: inspect(row.args))
          {:ok, _} = MyApp.Repo.insert(row)
          notify(conf, :inserted, row)
          maybe_schedule(conf, row, opts)
          {:ok, row}
        end

        defp build_row(changeset, _opts), do: changeset
        defp notify(_, _, _), do: :ok
        defp maybe_schedule(_, _, _), do: :ok
      end
      """

      assert_clean(BlackboxQuadrant, code, file: "lib/my_app/engines/postgres.ex")
    end
  end

  describe "regression: zip-pairing bug between public_fns and scores" do
    # `AST.extract_functions(:public)` and `Blackbox.score_module/1` may
    # return their function lists in DIFFERENT order. The previous code
    # `Enum.zip(public_fns, scores)` paired them positionally, which
    # silently mismatched: a pure changeset function would be flagged
    # under its name but with the failed-components of a completely
    # different function in the same module (e.g. an impure Repo.insert
    # wrapper). The diagnostic was correct about SOMETHING being impure
    # but pointed at the wrong function entirely.

    test "pure `changeset/2` is not flagged even when impure `insert/2` is in the same module" do
      code = ~S"""
      defmodule MyApp.EventLog do
        @moduledoc "Public context."
        import Ecto.Changeset

        defstruct [:message, :caller]

        # Pure: cast + validate_required only
        def changeset(event_log, attrs) do
          event_log
          |> cast(attrs, [:message, :caller])
          |> validate_required([:message, :caller])
        end

        # Impure: writes to Repo
        def insert(message, caller) do
          cs = changeset(%__MODULE__{}, %{message: message, caller: caller})
          Repo.insert(cs)
        end
      end
      """

      diagnostics =
        analyze(BlackboxQuadrant, code, file: "lib/my_app/event_log.ex")

      changeset_diags = Enum.filter(diagnostics, &(&1.message =~ "changeset/2"))

      assert changeset_diags == [],
             "pure changeset/2 must not be flagged; the zip-pairing bug paired insert/2's failures with changeset/2's name"
    end
  end
end
