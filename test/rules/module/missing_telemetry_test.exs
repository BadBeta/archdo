defmodule Archdo.Rules.Module.MissingTelemetryTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.MissingTelemetry

  defp parse(code, file) do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true, token_metadata: true)
    {file, ast}
  end

  test "flags context facade without telemetry" do
    # Facade file at lib/my_app/accounts.ex
    facade =
      parse(
        """
          defmodule MyApp.Accounts do
            def create_user(attrs), do: :ok
            def get_user(id), do: nil
            def delete_user(id), do: :ok
          end
        """,
        "lib/my_app/accounts.ex"
      )

    # Sub-module at lib/my_app/accounts/user.ex (proves accounts/ dir exists)
    sub =
      parse(
        """
          defmodule MyApp.Accounts.User do
            defstruct [:id, :name]
          end
        """,
        "lib/my_app/accounts/user.ex"
      )

    diags = MissingTelemetry.analyze_project([facade, sub])
    assert length(diags) == 1
    assert hd(diags).rule_id == "4.19"
    assert hd(diags).message =~ "telemetry"
  end

  test "allows facade with telemetry.span" do
    facade =
      parse(
        """
          defmodule MyApp.Accounts do
            def create_user(attrs) do
              :telemetry.span([:my_app, :accounts, :create_user], %{}, fn ->
                {:ok, %{}}
              end)
            end
            def get_user(id), do: nil
          end
        """,
        "lib/my_app/accounts.ex"
      )

    sub =
      parse(
        """
          defmodule MyApp.Accounts.User do
            defstruct [:id]
          end
        """,
        "lib/my_app/accounts/user.ex"
      )

    diags = MissingTelemetry.analyze_project([facade, sub])
    assert diags == []
  end

  test "skips modules with fewer than 2 public functions" do
    facade =
      parse(
        """
          defmodule MyApp.Tiny do
            def only_one, do: :ok
          end
        """,
        "lib/my_app/tiny.ex"
      )

    sub =
      parse(
        """
          defmodule MyApp.Tiny.Helper do
            def help, do: :ok
          end
        """,
        "lib/my_app/tiny/helper.ex"
      )

    diags = MissingTelemetry.analyze_project([facade, sub])
    assert diags == []
  end

  test "skips facades marked @archdo_no_telemetry" do
    # Two shapes the rule's heuristic can't detect cleanly:
    #   - pure-data lookup modules (telemetry overhead > lookup work)
    #   - library/CLI facades (consumer attaches handlers, not us)
    # Authors opt out with `@archdo_no_telemetry "<reason>"`.
    facade =
      parse(
        """
          defmodule MyApp.Constants do
            @archdo_no_telemetry "static lookup table — telemetry on lookup is overhead"
            def pass_for(rule_id), do: rule_id
            def all_passes, do: [1, 2, 3]
            def label_for(pass), do: to_string(pass)
          end
        """,
        "lib/my_app/constants.ex"
      )

    sub =
      parse(
        """
          defmodule MyApp.Constants.Internal do
            defstruct [:id]
          end
        """,
        "lib/my_app/constants/internal.ex"
      )

    diags = MissingTelemetry.analyze_project([facade, sub])
    assert diags == []
  end

  test "skips non-facade modules (no matching directory)" do
    standalone =
      parse(
        """
          defmodule MyApp.Utils do
            def helper_a, do: :ok
            def helper_b, do: :ok
            def helper_c, do: :ok
          end
        """,
        "lib/my_app/utils.ex"
      )

    diags = MissingTelemetry.analyze_project([standalone])
    assert diags == []
  end

  describe "library + NIF projects" do
    setup do
      root = Path.join(System.tmp_dir!(), "archdo_mt_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(Path.join(root, "lib/relix_array"))
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "skips when mix.exs has package/0 and codebase uses Rustler", %{root: root} do
      File.write!(Path.join(root, "mix.exs"), ~s|defmodule RelixArray.MixProject do
  use Mix.Project
  def project, do: [app: :relix_array, version: "0.1.0", package: package()]
  defp package, do: [licenses: ["MIT"]]
end|)

      facade =
        parse(
          """
            defmodule RelixArray do
              def a, do: :ok
              def b, do: :ok
              def c, do: :ok
            end
          """,
          Path.join(root, "lib/relix_array.ex")
        )

      native =
        parse(
          """
            defmodule RelixArray.Native do
              @moduledoc false
              use Rustler, otp_app: :relix_array
              def a, do: :erlang.nif_error(:not_loaded)
            end
          """,
          Path.join(root, "lib/relix_array/native.ex")
        )

      diags = MissingTelemetry.analyze_project([facade, native])
      assert diags == []
    end

    test "still flags when project is NOT a library (no package)", %{root: root} do
      File.write!(Path.join(root, "mix.exs"), ~s|defmodule App.MixProject do
  use Mix.Project
  def project, do: [app: :app, version: "0.1.0"]
end|)

      facade =
        parse(
          """
            defmodule App.Accounts do
              def a, do: :ok
              def b, do: :ok
              def c, do: :ok
            end
          """,
          Path.join(root, "lib/app/accounts.ex")
        )

      File.mkdir_p!(Path.join(root, "lib/app/accounts"))

      sub =
        parse(
          """
            defmodule App.Accounts.User do
              defstruct [:id]
            end
          """,
          Path.join(root, "lib/app/accounts/user.ex")
        )

      diags = MissingTelemetry.analyze_project([facade, sub])
      assert length(diags) == 1
    end

    test "still flags library WITHOUT NIF", %{root: root} do
      File.write!(Path.join(root, "mix.exs"), ~s|defmodule Lib.MixProject do
  use Mix.Project
  def project, do: [app: :lib, version: "0.1.0", package: package()]
  defp package, do: [licenses: ["MIT"]]
end|)

      facade =
        parse(
          """
            defmodule Lib.Accounts do
              def a, do: :ok
              def b, do: :ok
              def c, do: :ok
            end
          """,
          Path.join(root, "lib/lib/accounts.ex")
        )

      File.mkdir_p!(Path.join(root, "lib/lib/accounts"))

      sub =
        parse(
          """
            defmodule Lib.Accounts.User do
              defstruct [:id]
            end
          """,
          Path.join(root, "lib/lib/accounts/user.ex")
        )

      diags = MissingTelemetry.analyze_project([facade, sub])
      assert length(diags) == 1
    end
  end
end
