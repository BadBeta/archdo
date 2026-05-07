defmodule Archdo.Rules.Module.EncoderWithoutDecoderTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.EncoderWithoutDecoder

  describe "encoder without decoder" do
    test "flags `to_xml/1` with no `from_xml`/`parse_xml`/`decode_xml`" do
      code = ~S"""
      defmodule MyApp.Document do
        defstruct [:body]

        def to_xml(%__MODULE__{body: b}), do: "<doc>#{b}</doc>"
      end
      """

      [diag] = assert_flagged(EncoderWithoutDecoder, code)
      assert diag.rule_id == "6.102"
      assert diag.severity == :info
      assert diag.message =~ "to_xml"
    end

    test "flags `to_proto/1` with no decoder" do
      code = ~S"""
      defmodule MyApp.Message do
        def to_proto(msg), do: Protobuf.encode(msg)
      end
      """

      [diag] = assert_flagged(EncoderWithoutDecoder, code)
      assert diag.message =~ "to_proto"
    end

    test "flags `to_csv/1` with no decoder" do
      code = ~S"""
      defmodule MyApp.Record do
        def to_csv(r), do: "#{r.id},#{r.name}"
      end
      """

      [_diag] = assert_flagged(EncoderWithoutDecoder, code)
    end
  end

  describe "clean code" do
    test "does not flag when from_X exists" do
      code = ~S"""
      defmodule MyApp.Email do
        def to_string(e), do: e.address
        def from_string(s), do: %{address: s}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag when parse_X exists" do
      code = ~S"""
      defmodule MyApp.Email do
        def to_string(e), do: e.address
        def parse_string(s), do: {:ok, s}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag when decode_X exists" do
      code = ~S"""
      defmodule MyApp.Token do
        def to_json(t), do: Jason.encode!(t)
        def decode_json(s), do: Jason.decode!(s)
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag arity != 1" do
      code = ~S"""
      defmodule MyApp.Lib do
        def to_iodata(a, b), do: [a, b]
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag private fn" do
      code = ~S"""
      defmodule MyApp.Lib do
        defp to_string(_), do: ""
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.LibTest do
        def to_json(t), do: Jason.encode!(t)
      end
      """

      assert_clean(EncoderWithoutDecoder, code, file: "test/lib_test.exs")
    end
  end

  describe "FP filters — external-API / lossy / stdlib" do
    test "does not flag `to_stripe/1` (external-API serializer)" do
      code = ~S"""
      defmodule MyApp.Payment do
        def to_stripe(payment), do: %{amount: payment.amount, currency: "usd"}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_minor_units/1` (lossy projection)" do
      code = ~S"""
      defmodule MyApp.Money do
        def to_minor_units(money), do: round(money.amount * 100)
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_date!/1` (stdlib wrapper)" do
      code = ~S"""
      defmodule MyApp.Util do
        def to_date!(s), do: Date.from_iso8601!(s)
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    # FP class 4 — internal-projection names. These project a parent struct
    # onto a sibling/summary struct (e.g., livebook's `Hubs.Personal.to_metadata/1`
    # → `%Hubs.Metadata{}`). The reverse direction doesn't exist in the parent
    # module by design; round-trip is impossible because the projection drops
    # fields. Same shape as algora's `to_domain/1`.
    test "does not flag `to_metadata/1` (internal projection)" do
      code = ~S"""
      defmodule MyApp.Hubs.Personal do
        def to_metadata(personal) do
          %{id: personal.id, name: personal.name}
        end
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_view/1` (Phoenix view-model projection)" do
      code = ~S"""
      defmodule MyApp.Posts.Post do
        def to_view(post), do: %{title: post.title, author: post.author.name}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_summary/1` (summary projection)" do
      code = ~S"""
      defmodule MyApp.Reports.Report do
        def to_summary(report), do: %{total: report.total, count: report.count}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_dto/1` (DTO projection)" do
      code = ~S"""
      defmodule MyApp.User do
        def to_dto(user), do: %{id: user.id, name: user.name}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_params/1` (params projection)" do
      code = ~S"""
      defmodule MyApp.Form do
        def to_params(form), do: %{name: form.name, age: form.age}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end
  end

  describe "FP filter — external-service prefix patterns" do
    # Library-prefix patterns: name starts with `to_<service>_` where the
    # service is a known external API (Stripe, Brod/Kafka, BigQuery, Slack, etc.)
    test "does not flag `to_stripe_currency/1` (Stripe-prefix)" do
      code = ~S"""
      defmodule MyApp.MoneyUtils do
        def to_stripe_currency(money), do: %{amount: money.amount, currency: "usd"}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_brod_config/1` (Brod/Kafka-prefix)" do
      code = ~S"""
      defmodule MyApp.KafkaSink do
        def to_brod_config(sink), do: %{hosts: sink.hosts, topic: sink.topic}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_bq_interval_token/1` (BigQuery-prefix)" do
      code = ~S"""
      defmodule MyApp.BqQuery do
        def to_bq_interval_token(interval), do: "INTERVAL '#{interval}' DAY"
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_rich_text_preformatted/1` (Slack rich-text prefix)" do
      code = ~S"""
      defmodule MyApp.SlackAdaptor do
        def to_rich_text_preformatted(text), do: %{type: "rich_text_preformatted", text: text}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end
  end

  describe "FP filter — lossy projection extras" do
    # `to_local_string` — i18n / locale projection; drops the underlying value's
    # type info. Algora pattern.
    test "does not flag `to_local_string/1` (locale projection)" do
      code = ~S"""
      defmodule MyApp.Util do
        def to_local_string(n), do: :erlang.float_to_binary(n, decimals: 2)
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    # `to_domain` — extracts a domain name from a URL or struct. Lossy
    # projection. Algora pattern.
    test "does not flag `to_domain/1` (domain extraction)" do
      code = ~S"""
      defmodule MyApp.Util do
        def to_domain(url), do: URI.parse(url).host
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end
  end

  describe "FP filter — suffix patterns" do
    # `_opts` suffix: configuration/options projection for an external library.
    # Round-trip not expected; opts are produced FOR the library, not from it.
    test "does not flag `to_postgrex_opts/1` (_opts suffix)" do
      code = ~S"""
      defmodule MyApp.Db do
        def to_postgrex_opts(db), do: [hostname: db.host, port: db.port]
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_protocol_opts/1` (_opts suffix)" do
      code = ~S"""
      defmodule MyApp.Db do
        def to_protocol_opts(db), do: [ssl: db.ssl?]
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    # `_types` / `_type` suffix: type-mapping projection. e.g. pleroma's
    # `to_json_types` and `to_elixir_types` form a pair, but neither is a
    # round-trippable encoder; both are projections through a type system.
    test "does not flag `to_json_types/1` (_types suffix)" do
      code = ~S"""
      defmodule MyApp.Config do
        def to_json_types(config), do: %{values: Enum.map(config, &cast/1)}
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_schema_type/1` (_type suffix)" do
      code = ~S"""
      defmodule MyApp.BqSchema do
        def to_schema_type(:string), do: "STRING"
        def to_schema_type(:int), do: "INTEGER"
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end
  end

  describe "FP filter — additional library/service prefixes" do
    # Mastodon API in pleroma
    test "does not flag `to_masto_date/1` (Mastodon prefix)" do
      code = ~S"""
      defmodule MyApp.MastoApi do
        def to_masto_date(dt), do: DateTime.to_iso8601(dt)
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    # Timex library wrapper in logflare
    test "does not flag `to_timex_shift_key/1` (Timex prefix)" do
      code = ~S"""
      defmodule MyApp.Time do
        def to_timex_shift_key(:day), do: :days
        def to_timex_shift_key(:hour), do: :hours
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    # `to_param/1` is the Phoenix.Param protocol method. Its inverse is
    # route matching, not a `from_param` function. Hexpm pattern.
    test "does not flag `to_param/1` (Phoenix.Param protocol)" do
      code = ~S"""
      defimpl Phoenix.Param, for: MyApp.Release do
        def to_param(release), do: to_string(release.version)
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end
  end

  describe "M-fp-E3: AST-shape projection detection" do
    # FP class 7 — body-shape projection. A `to_X/1` whose top-level body is
    # a map literal `%{...}` or struct literal `%Mod{...}` is structurally a
    # projection. Round-trip is rarely meaningful — the literal drops fields
    # by design. Catches domain-specific names not in the curated lists
    # (logflare's `to_dialect`/`to_typemap`, sequin's `to_external`, etc.)
    # without growing those lists indefinitely.

    test "does not flag `to_dialect/1` whose body is a map literal (logflare pattern)" do
      code = ~S"""
      defmodule Logflare.Backends.SqlDialect do
        def to_dialect(:postgres) do
          %{prefix: "postgres", boolean: :native, jsonb: :native}
        end

        def to_dialect(:bigquery) do
          %{prefix: "bigquery", boolean: :int, jsonb: :string}
        end
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_typemap/1` whose body is a map literal" do
      code = ~S"""
      defmodule Logflare.Schema.Types do
        def to_typemap(_types) do
          %{int: :integer, str: :string, bool: :boolean}
        end
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_external/1` whose body is a struct literal" do
      code = ~S"""
      defmodule Sequin.Sources.Endpoint do
        defstruct [:id, :host, :port]

        def to_external(endpoint) do
          %ExternalEndpoint{id: endpoint.id, host: endpoint.host}
        end
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "STILL flags `to_querystring/1` whose body is a pipeline (real serializer)" do
      # Pipeline ending in a function call is NOT a literal projection —
      # it's a real serialization step. Body-shape filter must not suppress.
      code = ~S"""
      defmodule MyApp.Filter do
        def to_querystring(filter) do
          filter
          |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
          |> Enum.join("&")
        end
      end
      """

      [diag] = assert_flagged(EncoderWithoutDecoder, code)
      assert diag.rule_id == "6.102"
      assert diag.message =~ "to_querystring"
    end

    test "STILL flags `to_xml/1` whose body is binary concat (real encoder)" do
      # Binary concat is genuine encoding — NOT a literal projection.
      # Regression guard: existing to_xml test must keep firing.
      code = ~S"""
      defmodule MyApp.Doc do
        def to_xml(doc) do
          "<doc>" <> doc.body <> "</doc>"
        end
      end
      """

      [diag] = assert_flagged(EncoderWithoutDecoder, code)
      assert diag.rule_id == "6.102"
      assert diag.message =~ "to_xml"
    end

    test "does not flag `to_dialect/1` with single-expression block body containing map literal" do
      # `def f(x) do %{...} end` — body wrapped in __block__ but terminal
      # expression is the map literal. Body-shape filter must look through
      # the block.
      code = ~S"""
      defmodule MyApp.Dialect do
        def to_dialect(name) do
          %{name: name, kind: :sql}
        end
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "does not flag `to_dialect/1` with multi-statement block ending in map literal" do
      # Block with intermediate computation, terminal map literal.
      # The fact that there's a `case` first doesn't change the projection
      # shape — final expression is still a literal.
      code = ~S"""
      defmodule MyApp.Dialect do
        def to_config(name) do
          kind = case name do
            :pg -> :postgres
            :my -> :mysql
          end
          %{name: name, kind: kind}
        end
      end
      """

      assert_clean(EncoderWithoutDecoder, code)
    end

    test "STILL flags `to_xml/1` with multi-statement block ending in function call" do
      # Regression guard — block-bodied function whose terminal expression
      # is a call (not a literal) is a real encoder.
      code = ~S"""
      defmodule MyApp.Doc do
        def to_xml(doc) do
          escaped = String.replace(doc.body, "<", "&lt;")
          "<doc>" <> escaped <> "</doc>"
        end
      end
      """

      [diag] = assert_flagged(EncoderWithoutDecoder, code)
      assert diag.rule_id == "6.102"
    end
  end
end
