defmodule Archdo.VolatilityTest do
  use ExUnit.Case, async: true

  alias Archdo.Volatility

  defp parse(code, file \\ "lib/test_module.ex") do
    {:ok, ast} =
      Code.string_to_quoted(code,
        file: file,
        columns: true,
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {file, ast}
  end

  describe "per-dependency tag dispatch (default profile)" do
    test "module calling only :stable deps is :stable" do
      {file, ast} =
        parse("""
        defmodule MyApp.Pure do
          def normalize(s), do: URI.parse(s)
          def encode(m), do: Jason.encode!(m)
        end
        """)

      assert %{tag: :stable} = Volatility.classify_module(file, ast)
    end

    test "module calling :volatile deps is :volatile" do
      {file, ast} =
        parse("""
        defmodule MyApp.HttpAdapter do
          def fetch(url), do: Tesla.get(url)
          def post(url, body), do: Tesla.post(url, body)
        end
        """)

      assert %{tag: :volatile} = Volatility.classify_module(file, ast)
    end

    test "module calling :non_deterministic deps is :volatile (counts toward density)" do
      {file, ast} =
        parse("""
        defmodule MyApp.IdGen do
          def make, do: :rand.uniform(1_000_000)
        end
        """)

      assert %{tag: :volatile} = Volatility.classify_module(file, ast)
    end

    test "module calling :stable_with_test_seam deps does NOT count toward volatile density" do
      {file, ast} =
        parse("""
        defmodule MyApp.Reader do
          def fetch(id), do: Ecto.Repo.get(MyApp.Repo, MyApp.User, id)
          def normalize(s), do: URI.parse(s)
        end
        """)

      classification = Volatility.classify_module(file, ast)
      assert classification.tag == :stable
    end

    test "module with no classified calls is :stable (no evidence of volatility)" do
      {file, ast} =
        parse("""
        defmodule MyApp.PureLogic do
          def add(a, b), do: a + b
          def double(x), do: x * 2
        end
        """)

      assert %{tag: :stable, density: +0.0} = Volatility.classify_module(file, ast)
    end

    test "vendor SDK pattern (`*_sdk` / `ex_aws`) is :volatile" do
      {file, ast} =
        parse("""
        defmodule MyApp.S3Client do
          def get(bucket, key), do: ExAws.S3.get_object(bucket, key) |> ExAws.request()
        end
        """)

      assert %{tag: :volatile} = Volatility.classify_module(file, ast)
    end
  end

  describe "dual-purpose modules — call-site granularity" do
    test "DateTime.from_iso8601/1 is :stable (parsing existing data)" do
      {file, ast} =
        parse("""
        defmodule MyApp.Parser do
          def parse(s), do: DateTime.from_iso8601(s)
        end
        """)

      assert %{tag: :stable} = Volatility.classify_module(file, ast)
    end

    test "DateTime.utc_now/0 is :non_deterministic (clock read)" do
      {file, ast} =
        parse("""
        defmodule MyApp.Clock do
          def now, do: DateTime.utc_now()
        end
        """)

      assert %{tag: :volatile} = Volatility.classify_module(file, ast)
    end

    test ":inet.parse_address/1 is :stable (pure parse)" do
      {file, ast} =
        parse("""
        defmodule MyApp.IpParser do
          def parse(s), do: :inet.parse_address(s)
        end
        """)

      assert %{tag: :stable} = Volatility.classify_module(file, ast)
    end

    test ":inet.getaddr/2 is :non_deterministic (DNS lookup)" do
      {file, ast} =
        parse("""
        defmodule MyApp.DnsLookup do
          def lookup(host), do: :inet.getaddr(host, :inet)
        end
        """)

      assert %{tag: :volatile} = Volatility.classify_module(file, ast)
    end
  end

  describe "path-based override" do
    test "module under `volatile_paths` is unconditionally :volatile" do
      {file, ast} =
        parse(
          """
          defmodule MyApp.Integrations.Foo do
            def add(a, b), do: a + b
          end
          """,
          "lib/my_app/integrations/foo.ex"
        )

      classification =
        Volatility.classify_module(file, ast,
          volatile_paths: ["lib/my_app/integrations/**"]
        )

      assert classification.tag == :volatile
      assert classification.evidence.override == :path
    end

    test "module under `stable_paths` is unconditionally :stable" do
      {file, ast} =
        parse(
          """
          defmodule MyApp.Domain.Calculator do
            def fetch(url), do: Tesla.get(url)
          end
          """,
          "lib/my_app/domain/calculator.ex"
        )

      classification =
        Volatility.classify_module(file, ast,
          stable_paths: ["lib/my_app/domain/**"]
        )

      assert classification.tag == :stable
      assert classification.evidence.override == :path
    end

    test "no override applies when path doesn't match" do
      {file, ast} =
        parse(
          """
          defmodule MyApp.Other.Foo do
            def fetch(url), do: Tesla.get(url)
          end
          """,
          "lib/my_app/other/foo.ex"
        )

      classification =
        Volatility.classify_module(file, ast,
          volatile_paths: ["lib/my_app/integrations/**"]
        )

      assert classification.evidence.override == nil
      assert classification.tag == :volatile
    end
  end

  describe "author override (@archdo_volatility module attribute)" do
    test "@archdo_volatility :stable forces :stable even with volatile calls" do
      {file, ast} =
        parse("""
        defmodule MyApp.HelperUsingHttp do
          @archdo_volatility :stable
          def safe_wrapper(url), do: Tesla.get(url)
        end
        """)

      classification = Volatility.classify_module(file, ast)
      assert classification.tag == :stable
      assert classification.evidence.override == :author
    end

    test "@archdo_volatility :volatile forces :volatile even with no volatile calls" do
      {file, ast} =
        parse("""
        defmodule MyApp.MarkedVolatile do
          @archdo_volatility :volatile
          def trivial(x), do: x
        end
        """)

      classification = Volatility.classify_module(file, ast)
      assert classification.tag == :volatile
      assert classification.evidence.override == :author
    end
  end

  describe "density computation + thresholds" do
    test "density = (volatile + non_deterministic) / total_classified_calls" do
      {file, ast} =
        parse("""
        defmodule MyApp.Mixed do
          def a, do: Tesla.get("/a")
          def b, do: URI.parse("/b")
          def c, do: URI.parse("/c")
          def d, do: URI.parse("/d")
        end
        """)

      classification = Volatility.classify_module(file, ast)
      # 1 volatile out of 4 classified calls = 0.25
      assert_in_delta classification.density, 0.25, 0.001
    end

    test "density >= 0.40 → :volatile" do
      {file, ast} =
        parse("""
        defmodule MyApp.Borderline do
          def a, do: Tesla.get("/a")
          def b, do: Tesla.get("/b")
          def c, do: URI.parse("/c")
        end
        """)

      classification = Volatility.classify_module(file, ast)
      # 2/3 = 0.66 → volatile
      assert classification.tag == :volatile
    end

    test "density between 0.05 and 0.40 → :mixed" do
      {file, ast} =
        parse("""
        defmodule MyApp.MixedDensity do
          def a, do: Tesla.get("/a")
          def b, do: URI.parse("/b")
          def c, do: URI.parse("/c")
          def d, do: URI.parse("/d")
          def e, do: URI.parse("/e")
        end
        """)

      classification = Volatility.classify_module(file, ast)
      # 1/5 = 0.20 → mixed
      assert classification.tag == :mixed
    end
  end

  describe "evidence map" do
    test "carries the volatile call list with module/function/arity" do
      {file, ast} =
        parse("""
        defmodule MyApp.Sample do
          def go(url), do: Tesla.get(url)
        end
        """)

      classification = Volatility.classify_module(file, ast)
      assert {Tesla, :get, 1} in classification.evidence.volatile_calls
    end

    test "carries reason string from the dependency profile entry" do
      {file, ast} =
        parse("""
        defmodule MyApp.Sample do
          def go(url), do: Tesla.get(url)
        end
        """)

      classification = Volatility.classify_module(file, ast)
      reasons = Enum.map(classification.evidence.volatile_calls, &elem(&1, 0))
      reasons_for_tesla = classification.evidence.tag_rationale[Tesla]
      assert Tesla in reasons
      assert is_binary(reasons_for_tesla)
      assert reasons_for_tesla =~ "HTTP"
    end
  end

  describe "mixed?/1 helper" do
    test "true for :mixed classifications" do
      assert Volatility.mixed?(%{tag: :mixed})
    end

    test "false for :stable / :volatile" do
      refute Volatility.mixed?(%{tag: :stable})
      refute Volatility.mixed?(%{tag: :volatile})
    end
  end

  describe "classification_for/3" do
    test "uses cached opts[:volatility] when present (no re-walk)" do
      cached = %{tag: :stable, evidence: :cached_marker}
      {file, ast} = parse("defmodule X do; def f(x), do: x; end")
      assert Volatility.classification_for(file, ast, volatility: cached) == cached
    end

    test "falls back to classify_module/2 when opts has no :volatility" do
      {file, ast} =
        parse("""
        defmodule MyApp.Sample do
          def go(url), do: Tesla.get(url)
        end
        """)

      result = Volatility.classification_for(file, ast, [])
      assert result.tag == :volatile
    end

    test "falls back to classify_module/2 when opts is not a list" do
      {file, ast} = parse("defmodule X do; def f(x), do: x; end")
      result = Volatility.classification_for(file, ast, nil)
      assert result.tag in [:stable, :mixed, :volatile, :non_deterministic]
    end
  end
end
