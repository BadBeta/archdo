defmodule Archdo.Rules.Module.UnboundedExternalCallTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.UnboundedExternalCall

  defp analyze(code, file \\ "lib/my_app/service.ex") do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true, token_metadata: true)
    UnboundedExternalCall.analyze(file, ast, [])
  end

  test "flags HTTPoison.get without timeout" do
    diags =
      analyze("""
        defmodule MyApp.Service do
          def fetch(url), do: HTTPoison.get(url)
        end
      """)

    assert length(diags) == 1
    assert hd(diags).rule_id == "4.18"
    assert hd(diags).message =~ "timeout"
  end

  test "allows HTTPoison.get with recv_timeout" do
    diags =
      analyze("""
        defmodule MyApp.Service do
          def fetch(url), do: HTTPoison.get(url, [], recv_timeout: 5000)
        end
      """)

    assert diags == []
  end

  test "allows HTTPoison.get with timeout" do
    diags =
      analyze("""
        defmodule MyApp.Service do
          def fetch(url), do: HTTPoison.get(url, [], timeout: 5000)
        end
      """)

    assert diags == []
  end

  test "flags Req.get without timeout" do
    diags =
      analyze("""
        defmodule MyApp.Service do
          def fetch(url), do: Req.get(url)
        end
      """)

    assert length(diags) == 1
    assert hd(diags).message =~ "Req.get"
  end

  test "allows Req.get with receive_timeout" do
    diags =
      analyze("""
        defmodule MyApp.Service do
          def fetch(url), do: Req.get(url, receive_timeout: 5000)
        end
      """)

    assert diags == []
  end

  test "flags GenServer.call without explicit timeout as info" do
    diags =
      analyze("""
        defmodule MyApp.Service do
          def get_state(pid), do: GenServer.call(pid, :get)
        end
      """)

    assert length(diags) == 1
    assert hd(diags).severity == :info
    assert hd(diags).message =~ "GenServer.call"
  end

  test "allows GenServer.call with explicit timeout" do
    diags =
      analyze("""
        defmodule MyApp.Service do
          def get_state(pid), do: GenServer.call(pid, :get, 10_000)
        end
      """)

    assert diags == []
  end

  test "skips test files" do
    diags =
      analyze(
        """
          defmodule MyApp.ServiceTest do
            def test_fetch, do: HTTPoison.get("http://test.com")
          end
        """,
        "test/my_app/service_test.exs"
      )

    assert diags == []
  end
end
