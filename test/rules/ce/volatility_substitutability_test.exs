defmodule Archdo.Rules.CE.VolatilitySubstitutabilityTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.CE.VolatilitySubstitutability, as: VS

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

  defp analyze(file_asts), do: VS.analyze_project(file_asts)

  describe "policy cells" do
    test "{:low, :volatile} fires CE-2 (volatile boundary lacks abstraction)" do
      # A volatile module (calls Tesla) with zero abstraction
      # surface — no behaviours, no protocols, no injection points.
      vol_module =
        parse(
          """
          defmodule MyApp.Adapter do
            def fetch(url), do: Tesla.get(url)
            def post(url, body), do: Tesla.post(url, body)
          end
          """,
          "lib/my_app/adapter.ex"
        )

      diags = analyze([vol_module])
      assert Enum.any?(diags, &(&1.rule_id == "CE-2"))
    end

    test "{:high, :stable} fires CE-3 (stable core with abstraction overhead)" do
      # Two modules: one stable + heavily-abstract (uses many behaviours
      # without defining one), one stable + simple. Median is low; the
      # abstract one is well above 2× median.
      #
      # IMPORTANT: a module that DEFINES a behaviour (`@callback ...` or
      # `defprotocol ...`) is exempt — high abstraction density there is
      # by-design, not overhead. Use `@behaviour` (consumes) here, not
      # `@callback` (defines), to keep CE-3 firing.
      abstract_stable =
        parse(
          """
          defmodule MyApp.Domain.Calculator do
            @behaviour MyApp.SomeBehaviour
            @behaviour MyApp.OtherBehaviour
            @behaviour MyApp.ThirdBehaviour
            def add(a, b), do: a + b
          end
          """,
          "lib/my_app/domain/calculator.ex"
        )

      simple_stable =
        parse(
          """
          defmodule MyApp.Domain.Plain do
            def add(a, b), do: a + b
          end
          """,
          "lib/my_app/domain/plain.ex"
        )

      diags = analyze([abstract_stable, simple_stable])
      assert Enum.any?(diags, &(&1.rule_id == "CE-3"))
    end

    test "behaviour-defining module does NOT fire CE-3 (the abstraction IS the API)" do
      behaviour_module =
        parse(
          """
          defmodule MyApp.Storage do
            @callback get(String.t()) :: {:ok, term()} | {:error, term()}
            @callback put(String.t(), term()) :: :ok | {:error, term()}
            @callback delete(String.t()) :: :ok
          end
          """,
          "lib/my_app/storage.ex"
        )

      simple_stable =
        parse(
          """
          defmodule MyApp.Plain do
            def add(a, b), do: a + b
          end
          """,
          "lib/my_app/plain.ex"
        )

      diags = analyze([behaviour_module, simple_stable])
      refute Enum.any?(diags, &(&1.rule_id == "CE-3"))
    end

    test "{:high, :volatile} does NOT fire (abstraction is earned at the boundary)" do
      vol_module =
        parse(
          """
          defmodule MyApp.HttpAdapter do
            @callback get(url :: String.t()) :: {:ok, map()} | {:error, term()}
            def get(url), do: Tesla.get(url)
          end
          """,
          "lib/my_app/http_adapter.ex"
        )

      assert analyze([vol_module]) == []
    end

    test "{:low, :stable} does NOT fire (simplicity is correct)" do
      stable_module =
        parse(
          """
          defmodule MyApp.Pure do
            def normalize(s), do: URI.parse(s)
          end
          """,
          "lib/my_app/pure.ex"
        )

      assert analyze([stable_module]) == []
    end

    test "{_, :mixed} does NOT fire (mixed is CE-4's territory)" do
      mixed =
        parse(
          """
          defmodule MyApp.MixedDensity do
            def a, do: Tesla.get("/a")
            def b, do: URI.parse("/b")
            def c, do: URI.parse("/c")
            def d, do: URI.parse("/d")
            def e, do: URI.parse("/e")
          end
          """,
          "lib/my_app/mixed.ex"
        )

      diags = analyze([mixed])
      refute Enum.any?(diags, &(&1.rule_id in ["CE-2", "CE-3"]))
    end
  end

  describe "abstraction_density/1" do
    test "counts @callback, @behaviour, defprotocol declarations" do
      {_, ast} =
        parse(
          """
          defmodule MyApp.Heavy do
            @behaviour MyApp.A
            @behaviour MyApp.B
            @callback foo() :: :ok
            def f1, do: :ok
            def f2, do: :ok
            def f3, do: :ok
            def f4, do: :ok
          end
          """,
          "lib/my_app/heavy.ex"
        )

      assert VS.abstraction_density(ast) == 3 / 4
    end

    test "returns 0.0 for a module with no abstraction declarations" do
      {_, ast} =
        parse(
          """
          defmodule MyApp.Plain do
            def f1, do: :ok
            def f2, do: :ok
          end
          """,
          "lib/my_app/plain.ex"
        )

      assert VS.abstraction_density(ast) == 0.0
    end
  end

  describe "codebase median" do
    test "is computed from all classified modules' abstraction densities" do
      a = parse("defmodule A do; def x, do: :ok; end", "lib/a.ex")
      b = parse("defmodule B do; def x, do: :ok; end", "lib/b.ex")
      c = parse("defmodule C do; @callback x() :: :ok; def x, do: :ok; end", "lib/c.ex")

      # Densities: A 0, B 0, C 1.0 → median = 0.0
      assert VS.codebase_median([a, b, c]) == 0.0
    end
  end
end
