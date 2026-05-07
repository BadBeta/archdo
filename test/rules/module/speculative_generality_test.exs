defmodule Archdo.Rules.Module.SpeculativeGeneralityTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Module.SpeculativeGenerality

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

  describe "library mode — published behaviours for consumers" do
    # In a Hex package a behaviour with a real `@moduledoc """..."""` is
    # a CONTRACT for downstream consumers to implement. The library
    # itself ships no impl (the impls live in user apps). Without this
    # carve-out, every published-for-consumers behaviour fires 4.10.

    test "does NOT fire on a public behaviour (real @moduledoc) when library?: true" do
      file_asts = [
        parse(
          """
          defmodule MyLib.PoolBehaviour do
            @moduledoc \"\"\"
            A behaviour for users to implement custom connection pools.
            \"\"\"

            @callback checkout(any) :: {:ok, term()} | {:error, term()}
            @callback checkin(term(), any) :: :ok
          end
          """,
          "lib/my_lib/pool_behaviour.ex"
        )
      ]

      assert SpeculativeGenerality.analyze_project(file_asts, library?: true) == []
    end

    test "STILL fires on a @moduledoc-false behaviour with no impls in library mode" do
      # An internal behaviour with no impls IS dead code in a library too
      # — it claims internal-use intent, so impls should exist somewhere
      # in the same project.
      file_asts = [
        parse(
          """
          defmodule MyLib.Internal.Behaviour do
            @moduledoc false
            @callback go() :: :ok
          end
          """,
          "lib/my_lib/internal/behaviour.ex"
        )
      ]

      assert [_diag] = SpeculativeGenerality.analyze_project(file_asts, library?: true)
    end

    test "STILL fires on the same public behaviour in app mode" do
      # In an app, a public behaviour without impls is genuinely
      # speculative — the app is the only consumer and ships its own impls.
      file_asts = [
        parse(
          """
          defmodule MyApp.PoolBehaviour do
            @moduledoc \"Public docs.\"
            @callback go() :: :ok
          end
          """,
          "lib/my_app/pool_behaviour.ex"
        )
      ]

      assert [_diag] = SpeculativeGenerality.analyze_project(file_asts, library?: false)
    end
  end
end
