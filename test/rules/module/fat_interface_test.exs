defmodule Archdo.Rules.Module.FatInterfaceTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.FatInterface

  defp parse(code, file) do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true, token_metadata: true)
    {file, ast}
  end

  defp analyze(file_asts), do: FatInterface.analyze_project(file_asts)

  test "flags implementation with no-op stub returning :ok" do
    behaviour = parse("""
      defmodule MyApp.Storage do
        @callback read(String.t()) :: {:ok, binary()} | {:error, term()}
        @callback write(String.t(), binary()) :: :ok | {:error, term()}
        @callback delete(String.t()) :: :ok | {:error, term()}
      end
    """, "lib/my_app/storage.ex")

    impl = parse("""
      defmodule MyApp.Storage.ReadOnly do
        @behaviour MyApp.Storage

        @impl true
        def read(path), do: File.read(path)

        @impl true
        def write(_path, _data), do: :ok

        @impl true
        def delete(_path), do: :ok
      end
    """, "lib/my_app/storage/read_only.ex")

    diags = analyze([behaviour, impl])
    assert length(diags) == 1
    [diag] = diags
    assert diag.rule_id == "4.21"
    assert diag.message =~ "ReadOnly"
    assert diag.message =~ "write/2"
    assert diag.message =~ "delete/1"
  end

  test "flags stub returning nil" do
    behaviour = parse("""
      defmodule MyApp.Cache do
        @callback get(String.t()) :: term()
        @callback put(String.t(), term()) :: :ok
      end
    """, "lib/my_app/cache.ex")

    impl = parse("""
      defmodule MyApp.Cache.Noop do
        @behaviour MyApp.Cache

        @impl true
        def get(_key), do: nil

        @impl true
        def put(_key, _val), do: :ok
      end
    """, "lib/my_app/cache/noop.ex")

    diags = analyze([behaviour, impl])
    assert length(diags) == 1
    assert hd(diags).message =~ "get/1"
    assert hd(diags).message =~ "put/2"
  end

  test "flags stub raising not implemented" do
    behaviour = parse("""
      defmodule MyApp.Notifier do
        @callback notify(String.t()) :: :ok
      end
    """, "lib/my_app/notifier.ex")

    impl = parse("""
      defmodule MyApp.Notifier.Stub do
        @behaviour MyApp.Notifier

        @impl true
        def notify(_msg), do: raise "not implemented"
      end
    """, "lib/my_app/notifier/stub.ex")

    diags = analyze([behaviour, impl])
    assert length(diags) == 1
    assert hd(diags).message =~ "notify/1"
  end

  test "allows implementation with real logic in all callbacks" do
    behaviour = parse("""
      defmodule MyApp.Store do
        @callback get(String.t()) :: term()
        @callback put(String.t(), term()) :: :ok
      end
    """, "lib/my_app/store.ex")

    impl = parse("""
      defmodule MyApp.Store.ETS do
        @behaviour MyApp.Store

        @impl true
        def get(key), do: :ets.lookup(:store, key)

        @impl true
        def put(key, val), do: :ets.insert(:store, {key, val})
      end
    """, "lib/my_app/store/ets.ex")

    diags = analyze([behaviour, impl])
    assert diags == []
  end

  test "allows implementations without @impl true" do
    behaviour = parse("""
      defmodule MyApp.Worker do
        @callback run() :: :ok
      end
    """, "lib/my_app/worker.ex")

    impl = parse("""
      defmodule MyApp.Worker.Noop do
        @behaviour MyApp.Worker
        def run, do: :ok
      end
    """, "lib/my_app/worker/noop.ex")

    # Without @impl true, we can't reliably associate the function with the behaviour
    diags = analyze([behaviour, impl])
    assert diags == []
  end

  test "returns empty when no behaviours exist" do
    module = parse("""
      defmodule MyApp.Plain do
        def foo, do: :ok
      end
    """, "lib/my_app/plain.ex")

    assert analyze([module]) == []
  end
end
