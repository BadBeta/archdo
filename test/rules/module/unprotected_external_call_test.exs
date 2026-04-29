defmodule Archdo.Rules.Module.UnprotectedExternalCallTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.UnprotectedExternalCall

  defp analyze(code, file \\ "lib/my_app/service.ex") do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true, token_metadata: true)
    UnprotectedExternalCall.analyze(file, ast, [])
  end

  test "flags HTTPoison.get!" do
    diags =
      analyze("""
        defmodule MyApp.Service do
          def fetch(url), do: HTTPoison.get!(url)
        end
      """)

    assert length(diags) == 1
    assert hd(diags).rule_id == "4.20"
    assert hd(diags).message =~ "HTTPoison.get!"
  end

  test "flags Req.post!" do
    diags =
      analyze("""
        defmodule MyApp.Service do
          def send(url, body), do: Req.post!(url, body: body)
        end
      """)

    assert length(diags) == 1
    assert hd(diags).message =~ "Req.post!"
  end

  test "allows non-bang variants" do
    diags =
      analyze("""
        defmodule MyApp.Service do
          def fetch(url), do: HTTPoison.get(url)
        end
      """)

    assert diags == []
  end

  test "skips test files" do
    diags =
      analyze(
        """
          defmodule MyApp.ServiceTest do
            def test_fetch, do: HTTPoison.get!("http://test.com")
          end
        """,
        "test/my_app/service_test.exs"
      )

    assert diags == []
  end

  test "skips adapter files" do
    diags =
      analyze(
        """
          defmodule MyApp.HttpAdapter do
            def fetch(url), do: HTTPoison.get!(url)
          end
        """,
        "lib/my_app/adapters/http_adapter.ex"
      )

    assert diags == []
  end

  test "skips Mix tasks (operational layer)" do
    diags =
      analyze(
        """
          defmodule Mix.Tasks.MyApp.Download do
            use Mix.Task
            def run(_), do: HTTPoison.get!("http://example.com")
          end
        """,
        "lib/mix/tasks/my_app.download.ex"
      )

    assert diags == []
  end

  test "flags ExAws.request!" do
    diags =
      analyze("""
        defmodule MyApp.S3 do
          def upload(op), do: ExAws.request!(op)
        end
      """)

    assert length(diags) == 1
    assert hd(diags).message =~ "ExAws.request!"
  end
end
