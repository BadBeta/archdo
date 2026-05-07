defmodule Archdo.AnchorSetTest do
  use ExUnit.Case, async: true

  alias Archdo.{AnchorSet, Graph}

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

  describe "compute/1 — anchor discovery" do
    test "detects `use Mix.Task` modules" do
      file_asts = [
        parse(
          """
          defmodule Mix.Tasks.MyApp.Backfill do
            use Mix.Task
            def run(_), do: :ok
          end
          """,
          "lib/mix/tasks/my_app.backfill.ex"
        )
      ]

      assert AnchorSet.compute(file_asts) |> MapSet.member?("Mix.Tasks.MyApp.Backfill")
    end

    test "detects `use Application` modules" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Application do
            use Application
            def start(_, _), do: Supervisor.start_link([], strategy: :one_for_one)
          end
          """,
          "lib/my_app/application.ex"
        )
      ]

      assert AnchorSet.compute(file_asts) |> MapSet.member?("MyApp.Application")
    end

    test "detects supervisor children listed in application.ex `children` list" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Application do
            use Application
            def start(_, _) do
              children = [
                MyApp.Repo,
                MyApp.Cache,
                {Phoenix.PubSub, name: MyApp.PubSub}
              ]
              Supervisor.start_link(children, strategy: :one_for_one)
            end
          end
          """,
          "lib/my_app/application.ex"
        )
      ]

      anchors = AnchorSet.compute(file_asts)
      assert MapSet.member?(anchors, "MyApp.Repo")
      assert MapSet.member?(anchors, "MyApp.Cache")
      assert MapSet.member?(anchors, "Phoenix.PubSub")
    end

    test "detects `use Phoenix.Router` modules" do
      file_asts = [
        parse(
          """
          defmodule MyAppWeb.Router do
            use Phoenix.Router
          end
          """,
          "lib/my_app_web/router.ex"
        )
      ]

      assert AnchorSet.compute(file_asts) |> MapSet.member?("MyAppWeb.Router")
    end

    test "detects `use Oban.Worker` modules" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Workers.Charge do
            use Oban.Worker, queue: :payments
            def perform(_), do: :ok
          end
          """,
          "lib/my_app/workers/charge.ex"
        )
      ]

      assert AnchorSet.compute(file_asts) |> MapSet.member?("MyApp.Workers.Charge")
    end

    test "detects @archdo_anchor markers" do
      file_asts = [
        parse(
          """
          defmodule MyApp.NifBindings do
            @archdo_anchor "called via :erpc from sibling node"
            def hello, do: :world
          end
          """,
          "lib/my_app/nif_bindings.ex"
        )
      ]

      assert AnchorSet.compute(file_asts) |> MapSet.member?("MyApp.NifBindings")
    end

    test "detects `use Phoenix.LiveView` modules" do
      file_asts = [
        parse(
          """
          defmodule MyAppWeb.PageLive do
            use Phoenix.LiveView
          end
          """,
          "lib/my_app_web/live/page_live.ex"
        )
      ]

      assert AnchorSet.compute(file_asts) |> MapSet.member?("MyAppWeb.PageLive")
    end

    test "detects `use Phoenix.View` modules" do
      # Phoenix views are dispatched by Phoenix's render pipeline at
      # runtime via apply/3 — `MyController` renders `MyView` by naming
      # convention. Every view is by definition framework-anchored.
      file_asts = [
        parse(
          """
          defmodule MyAppWeb.EpisodeView do
            use Phoenix.View, root: "lib/my_app_web/templates"
          end
          """,
          "lib/my_app_web/views/episode_view.ex"
        )
      ]

      assert AnchorSet.compute(file_asts) |> MapSet.member?("MyAppWeb.EpisodeView")
    end

    test "detects `use AppWeb, :view` (project-helper view convention)" do
      # Modern Phoenix apps define `MyAppWeb.__using__(:view)` that
      # in turn calls `use Phoenix.View`. Archdo can't expand the
      # macro — it sees only the outer `use AppWeb, :view`. Detect
      # via the second-arg atom matching `:view` (and other view-shape
      # atoms like `:admin_view`, `:html_view` that follow the same
      # framework-dispatched-by-naming-convention pattern).
      file_asts = [
        parse(
          """
          defmodule MyAppWeb.Admin.EpisodeView do
            use MyAppWeb, :admin_view
          end
          """,
          "lib/my_app_web/views/admin/episode_view.ex"
        )
      ]

      assert AnchorSet.compute(file_asts) |> MapSet.member?("MyAppWeb.Admin.EpisodeView")
    end

    test "M-Plan8b: detects child in nested `use Supervisor` init/1" do
      # Nested sub-supervisor (NOT use Application) — its children
      # were previously invisible to AnchorSet. They're real anchor
      # candidates because the nesting supervisor is itself anchored.
      file_asts = [
        parse(
          """
          defmodule MyApp.WorkersSupervisor do
            use Supervisor

            def start_link(opts) do
              Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
            end

            @impl true
            def init(_opts) do
              children = [
                MyApp.RateLimiter,
                MyApp.Cache,
                {MyApp.QueueWorker, queue: :default}
              ]
              Supervisor.init(children, strategy: :one_for_one)
            end
          end
          """,
          "lib/my_app/workers_supervisor.ex"
        )
      ]

      anchors = AnchorSet.compute(file_asts)
      assert MapSet.member?(anchors, "MyApp.RateLimiter")
      assert MapSet.member?(anchors, "MyApp.Cache")
      assert MapSet.member?(anchors, "MyApp.QueueWorker")
    end

    test "M-Plan8b: detects child in `use DynamicSupervisor` init/1" do
      file_asts = [
        parse(
          """
          defmodule MyApp.JobSupervisor do
            use DynamicSupervisor

            def start_link(arg) do
              DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
            end

            @impl true
            def init(_arg) do
              DynamicSupervisor.init(strategy: :one_for_one, extra_arguments: [MyApp.Job])
            end
          end
          """,
          "lib/my_app/job_supervisor.ex"
        )
      ]

      # The supervisor module itself is an anchor (use Supervisor /
      # DynamicSupervisor).
      anchors = AnchorSet.compute(file_asts)
      assert MapSet.member?(anchors, "MyApp.JobSupervisor")
    end
  end

  describe "closure/2 — transitive reachability from anchors" do
    test "includes anchors and modules reachable from them via the dep graph" do
      file_asts = [
        parse(
          """
          defmodule MyApp.Application do
            use Application
            def start(_, _) do
              MyApp.Boot.run()
              Supervisor.start_link([MyApp.Cache], strategy: :one_for_one)
            end
          end
          """,
          "lib/my_app/application.ex"
        ),
        parse(
          """
          defmodule MyApp.Boot do
            def run, do: MyApp.Helpers.warmup()
          end
          """,
          "lib/my_app/boot.ex"
        ),
        parse(
          """
          defmodule MyApp.Helpers do
            def warmup, do: :ok
          end
          """,
          "lib/my_app/helpers.ex"
        ),
        parse(
          """
          defmodule MyApp.Cache do
            def get(k), do: k
          end
          """,
          "lib/my_app/cache.ex"
        ),
        parse(
          """
          defmodule MyApp.Orphan do
            def lonely, do: :unreachable
          end
          """,
          "lib/my_app/orphan.ex"
        )
      ]

      anchors = AnchorSet.compute(file_asts)
      graph = Graph.build(file_asts)

      closure = AnchorSet.closure(anchors, graph)

      # Application is the anchor; Boot, Helpers (via Boot), Cache (supervised
      # child) all reachable. Orphan stays out.
      assert MapSet.member?(closure, "MyApp.Application")
      assert MapSet.member?(closure, "MyApp.Boot")
      assert MapSet.member?(closure, "MyApp.Helpers")
      assert MapSet.member?(closure, "MyApp.Cache")
      refute MapSet.member?(closure, "MyApp.Orphan")
    end
  end
end
