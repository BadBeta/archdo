defmodule Archdo.Rules.Testing.UntestedModuleTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Testing.UntestedModule

  describe "analyze/3" do
    test "flags source module with no test file" do
      code = ~S"""
      defmodule MyApp.Accounts.User do
        @moduledoc "User schema"
        def changeset(user, attrs), do: {user, attrs}
      end
      """

      # Use a path where no test file will exist
      diags =
        assert_flagged(UntestedModule, code, file: "lib/nonexistent_project/accounts/user.ex")

      assert hd(diags).rule_id == "7.25"
      assert hd(diags).message =~ "no test file"
    end

    test "skips internal modules with @moduledoc false" do
      code = ~S"""
      defmodule MyApp.Internal do
        @moduledoc false
        def helper, do: :ok
      end
      """

      assert_clean(UntestedModule, code, file: "lib/nonexistent_project/internal.ex")
    end

    test "skips migration files" do
      code = ~S"""
      defmodule MyApp.Repo.Migrations.CreateUsers do
        use Ecto.Migration

        def change do
          create table(:users) do
            add :name, :string
          end
        end
      end
      """

      assert_clean(UntestedModule, code,
        file: "lib/my_app/repo/migrations/20240101_create_users.ex"
      )
    end

    test "skips config files like router.ex and endpoint.ex" do
      code = ~S"""
      defmodule MyAppWeb.Router do
        use Phoenix.Router
        get "/", PageController, :index
      end
      """

      assert_clean(UntestedModule, code, file: "lib/my_app_web/router.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        use ExUnit.Case
        test "it works" do
          assert true
        end
      end
      """

      assert_clean(UntestedModule, code, file: "test/my_app/accounts_test.exs")
    end

    test "source_to_test_path/1 converts paths correctly" do
      assert UntestedModule.source_to_test_path("lib/my_app/accounts/user.ex") ==
               "test/my_app/accounts/user_test.exs"

      assert UntestedModule.source_to_test_path("lib/my_app_web/controllers/page_controller.ex") ==
               "test/my_app_web/controllers/page_controller_test.exs"
    end
  end

  describe "candidate_test_paths/2" do
    test "default candidates include nested and flat conventions" do
      candidates = UntestedModule.candidate_test_paths("lib/relix_array.ex", ["test"])
      assert "test/relix_array_test.exs" in candidates
    end

    test "nested module derives nested + flat candidates" do
      candidates = UntestedModule.candidate_test_paths("lib/relix_array/native.ex", ["test"])
      assert "test/relix_array/native_test.exs" in candidates
      assert "test/native_test.exs" in candidates
    end

    test "honors a custom test_paths list from mix.exs" do
      candidates = UntestedModule.candidate_test_paths("lib/foo.ex", ["test", "spec"])
      assert "test/foo_test.exs" in candidates
      assert "spec/foo_test.exs" in candidates
    end
  end

  describe "analyze/3 with on-disk fixture project" do
    setup do
      root = Path.join(System.tmp_dir!(), "archdo_um_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(Path.join(root, "lib"))
      File.mkdir_p!(Path.join(root, "test"))
      File.write!(Path.join(root, "mix.exs"), ~s|defmodule Foo.MixProject do
  use Mix.Project
  def project, do: [app: :foo, version: "0.1.0"]
end|)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "is satisfied by a flat test/<basename>_test.exs", %{root: root} do
      File.write!(
        Path.join(root, "lib/relix_array.ex"),
        "defmodule RelixArray do\n  def x, do: :ok\nend"
      )

      File.write!(
        Path.join(root, "test/relix_array_test.exs"),
        "defmodule RelixArrayTest do\nend"
      )

      assert_clean(UntestedModule, File.read!(Path.join(root, "lib/relix_array.ex")),
        file: Path.join(root, "lib/relix_array.ex")
      )
    end

    test "still flags when no candidate test file exists", %{root: root} do
      File.write!(
        Path.join(root, "lib/uncovered.ex"),
        "defmodule Uncovered do\n  def x, do: :ok\nend"
      )

      diags =
        assert_flagged(UntestedModule, File.read!(Path.join(root, "lib/uncovered.ex")),
          file: Path.join(root, "lib/uncovered.ex")
        )

      assert hd(diags).rule_id == "7.25"
    end

    test "honors test_paths from mix.exs", %{root: root} do
      File.write!(Path.join(root, "mix.exs"), ~s|defmodule Foo.MixProject do
  use Mix.Project
  def project, do: [app: :foo, version: "0.1.0", test_paths: ["spec"]]
end|)
      File.mkdir_p!(Path.join(root, "spec"))
      File.write!(Path.join(root, "lib/foo.ex"), "defmodule Foo do\n  def x, do: :ok\nend")
      File.write!(Path.join(root, "spec/foo_test.exs"), "defmodule FooTest do\nend")

      assert_clean(UntestedModule, File.read!(Path.join(root, "lib/foo.ex")),
        file: Path.join(root, "lib/foo.ex")
      )
    end

    test "skips Mix tasks (operational layer)" do
      code = ~S"""
      defmodule Mix.Tasks.MyApp.Sync do
        @moduledoc "sync the world"
        use Mix.Task
        def run(_), do: :ok
      end
      """

      assert_clean(UntestedModule, code, file: "lib/mix/tasks/my_app.sync.ex")
    end

    test "skips release.ex (operational layer)" do
      code = ~S"""
      defmodule MyApp.Release do
        @moduledoc "release helpers"
        def migrate, do: :ok
      end
      """

      assert_clean(UntestedModule, code, file: "lib/my_app/release.ex")
    end
  end
end
