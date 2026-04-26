defmodule Archdo.Rules.Boundary.SeamIntegrityTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Boundary.SeamIntegrity

  defp parse(code, file \\ "lib/test.ex") do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true, token_metadata: true)
    {file, ast}
  end

  defp analyze(file_asts) do
    SeamIntegrity.analyze_project(file_asts)
  end

  describe "behaviour seam bypass" do
    test "flags direct call to behaviour implementation from outside namespace" do
      behaviour =
        parse(
          """
            defmodule MyApp.Mailer do
              @callback send_email(String.t(), String.t()) :: :ok
            end
          """,
          "lib/my_app/mailer.ex"
        )

      implementation =
        parse(
          """
            defmodule MyApp.Mailer.SwooshAdapter do
              @behaviour MyApp.Mailer
              def send_email(to, body), do: :ok
            end
          """,
          "lib/my_app/mailer/swoosh_adapter.ex"
        )

      caller =
        parse(
          """
            defmodule MyApp.Orders do
              def create(params) do
                MyApp.Mailer.SwooshAdapter.send_email(params.to, params.body)
              end
            end
          """,
          "lib/my_app/orders.ex"
        )

      diagnostics = analyze([behaviour, implementation, caller])
      assert length(diagnostics) == 1
      [diag] = diagnostics
      assert diag.rule_id == "4.17"
      assert diag.severity == :warning
      assert diag.message =~ "MyApp.Orders calls MyApp.Mailer.SwooshAdapter"
      assert diag.message =~ "@behaviour MyApp.Mailer"
    end

    test "allows same-namespace call (facade wiring)" do
      behaviour =
        parse(
          """
            defmodule MyApp.Mailer do
              @callback send_email(String.t(), String.t()) :: :ok

              def send(to, body) do
                MyApp.Mailer.SwooshAdapter.send_email(to, body)
              end
            end
          """,
          "lib/my_app/mailer.ex"
        )

      implementation =
        parse(
          """
            defmodule MyApp.Mailer.SwooshAdapter do
              @behaviour MyApp.Mailer
              def send_email(to, body), do: :ok
            end
          """,
          "lib/my_app/mailer/swoosh_adapter.ex"
        )

      diagnostics = analyze([behaviour, implementation])
      assert diagnostics == []
    end

    test "allows supervisor calling implementation" do
      behaviour =
        parse(
          """
            defmodule MyApp.Mailer do
              @callback send_email(String.t()) :: :ok
            end
          """,
          "lib/my_app/mailer.ex"
        )

      implementation =
        parse(
          """
            defmodule MyApp.Mailer.SwooshAdapter do
              @behaviour MyApp.Mailer
              def send_email(to), do: :ok
            end
          """,
          "lib/my_app/mailer/swoosh_adapter.ex"
        )

      supervisor =
        parse(
          """
            defmodule MyApp.Supervisor do
              def start_link(_) do
                MyApp.Mailer.SwooshAdapter.start_link([])
              end
            end
          """,
          "lib/my_app/supervisor.ex"
        )

      diagnostics = analyze([behaviour, implementation, supervisor])
      assert diagnostics == []
    end

    test "allows test files calling implementations directly" do
      behaviour =
        parse(
          """
            defmodule MyApp.Mailer do
              @callback send_email(String.t()) :: :ok
            end
          """,
          "lib/my_app/mailer.ex"
        )

      implementation =
        parse(
          """
            defmodule MyApp.Mailer.SwooshAdapter do
              @behaviour MyApp.Mailer
              def send_email(to), do: :ok
            end
          """,
          "lib/my_app/mailer/swoosh_adapter.ex"
        )

      test_file =
        parse(
          """
            defmodule MyApp.Mailer.SwooshAdapterTest do
              def test_send do
                MyApp.Mailer.SwooshAdapter.send_email("test@test.com")
              end
            end
          """,
          "test/my_app/mailer/swoosh_adapter_test.exs"
        )

      diagnostics = analyze([behaviour, implementation, test_file])
      assert diagnostics == []
    end

    test "allows sibling implementation calling sibling" do
      behaviour =
        parse(
          """
            defmodule MyApp.Store do
              @callback get(String.t()) :: term()
            end
          """,
          "lib/my_app/store.ex"
        )

      impl_a =
        parse(
          """
            defmodule MyApp.Store.Redis do
              @behaviour MyApp.Store
              def get(key), do: nil
            end
          """,
          "lib/my_app/store/redis.ex"
        )

      impl_b =
        parse(
          """
            defmodule MyApp.Store.Cached do
              @behaviour MyApp.Store
              def get(key) do
                MyApp.Store.Redis.get(key)
              end
            end
          """,
          "lib/my_app/store/cached.ex"
        )

      diagnostics = analyze([behaviour, impl_a, impl_b])
      assert diagnostics == []
    end
  end

  describe "no seams in project" do
    test "returns empty when no behaviours or protocols exist" do
      module_a =
        parse(
          """
            defmodule MyApp.Foo do
              def bar, do: :ok
            end
          """,
          "lib/my_app/foo.ex"
        )

      module_b =
        parse(
          """
            defmodule MyApp.Baz do
              def qux, do: MyApp.Foo.bar()
            end
          """,
          "lib/my_app/baz.ex"
        )

      assert analyze([module_a, module_b]) == []
    end
  end

  describe "protocol seam bypass" do
    test "flags direct call to protocol implementation module" do
      protocol =
        parse(
          """
            defprotocol MyApp.Encoder do
              def encode(data)
            end
          """,
          "lib/my_app/encoder.ex"
        )

      implementation =
        parse(
          """
            defimpl MyApp.Encoder, for: Map do
              def encode(data), do: Jason.encode!(data)
            end
          """,
          "lib/my_app/encoder/map.ex"
        )

      caller =
        parse(
          """
            defmodule MyApp.API do
              def respond(data) do
                MyApp.Encoder.Map.encode(data)
              end
            end
          """,
          "lib/my_app/api.ex"
        )

      diagnostics = analyze([protocol, implementation, caller])
      assert length(diagnostics) == 1
      [diag] = diagnostics
      assert diag.message =~ "protocol"
    end
  end

  describe "diagnostic content" do
    test "includes fix alternatives" do
      behaviour =
        parse(
          """
            defmodule MyApp.Notifier do
              @callback notify(String.t()) :: :ok
            end
          """,
          "lib/my_app/notifier.ex"
        )

      implementation =
        parse(
          """
            defmodule MyApp.Notifier.Slack do
              @behaviour MyApp.Notifier
              def notify(msg), do: :ok
            end
          """,
          "lib/my_app/notifier/slack.ex"
        )

      caller =
        parse(
          """
            defmodule MyApp.Accounts do
              def welcome(user) do
                MyApp.Notifier.Slack.notify("Welcome!")
              end
            end
          """,
          "lib/my_app/accounts.ex"
        )

      [diag] = analyze([behaviour, implementation, caller])
      assert length(diag.alternatives) == 3
      assert hd(diag.alternatives).summary =~ "compile_env"
    end
  end
end
