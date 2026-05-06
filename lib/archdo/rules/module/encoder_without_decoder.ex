defmodule Archdo.Rules.Module.EncoderWithoutDecoder do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @decoder_prefixes ~w(from_ parse_ decode_)

  # FP class 1 — external-API serializers. Round-trip is owned by the
  # third-party service, not us; absence of a local decoder is by design.
  @external_service_serializer_names ~w(
    to_stripe to_intercom to_segment to_slack to_github to_jira to_linear
    to_zendesk to_freshdesk to_hubspot to_salesforce to_mailchimp to_sendgrid
    to_twilio to_pagerduty to_datadog to_newrelic to_sentry to_postmark
    to_resend to_brevo to_zoom to_calendly to_notion to_asana to_trello
  )

  # FP class 2 — lossy projections. Sub-component extraction; round-trip
  # impossible by design (`to_minor_units` discards major-unit info).
  @lossy_projection_names ~w(
    to_integer to_int to_float to_decimal to_number to_string to_atom
    to_charlist to_iodata to_binary to_boolean to_bool to_list to_map
    to_minor_units to_major_units to_cents to_currency to_keyword
    to_keyword_list to_tuple
  )

  # FP class 3 — stdlib-wrapper. Decoder lives in stdlib (`Date.from_iso8601`,
  # `URI.parse`, `Jason.decode`), not this module.
  @stdlib_wrapper_names ~w(
    to_date to_date! to_datetime to_datetime! to_naive_datetime
    to_naive_datetime! to_time to_time! to_iso8601 to_iso8601!
    to_uri to_url to_query to_json to_json!
  )

  # FP class 4 — internal-projection. Project a parent struct onto a sibling
  # / summary / view-model struct. Round-trip is impossible because the
  # projection drops fields by design; the inverse function legitimately
  # doesn't exist in the parent module.
  @internal_projection_names ~w(
    to_metadata to_view to_view_model to_summary to_dto to_record
    to_payload to_event to_struct to_form to_changeset to_params
    to_attrs to_args to_props to_data to_row to_entry to_domain
    to_local_string to_param
  )

  @fp_filtered_names @external_service_serializer_names ++
                       @lossy_projection_names ++
                       @stdlib_wrapper_names ++
                       @internal_projection_names

  # FP class 5 — external-service prefix patterns. A name starting with
  # `to_<service>_<anything>` where `<service>` is a known external-API
  # library is a service-specific serializer. Round-trip is owned by the
  # service, not by us. Examples: `to_stripe_currency`, `to_brod_config`,
  # `to_bq_interval_token`, `to_rich_text_preformatted` (Slack),
  # `to_masto_date` (Mastodon), `to_timex_shift_key` (Timex library).
  @external_service_serializer_prefixes ~w(
    to_stripe_ to_intercom_ to_segment_ to_slack_ to_github_ to_jira_
    to_linear_ to_zendesk_ to_freshdesk_ to_hubspot_ to_salesforce_
    to_mailchimp_ to_sendgrid_ to_twilio_ to_pagerduty_ to_datadog_
    to_newrelic_ to_sentry_ to_postmark_ to_resend_ to_brevo_
    to_zoom_ to_calendly_ to_notion_ to_asana_ to_trello_
    to_brod_ to_bq_ to_rich_text_ to_masto_ to_timex_
  )

  # FP class 6 — projection-suffix patterns. Function names ending in these
  # suffixes are conventional projections (config/options, type-mapping,
  # query/changeset/cast) where the inverse round-trip is not expected.
  # Examples: `to_postgrex_opts`, `to_protocol_opts`, `to_json_types`,
  # `to_elixir_types`, `to_schema_type`.
  @projection_suffixes ~w(_opts _types _type)

  @impl true
  def id, do: "6.102"

  @impl true
  def description,
    do: "Public `to_X/1` without matching decoder (`from_X` / `parse_X` / `decode_X`)"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_unpaired_encoders(file, ast)
    end
  end

  defp find_unpaired_encoders(file, ast) do
    public_fns = AST.extract_functions(ast, :public)
    fn_names = MapSet.new(public_fns, fn {name, _, _, _, _} -> Atom.to_string(name) end)

    public_fns
    |> Enum.filter(&encoder_to_x_one?/1)
    |> Enum.reject(&suppressed?(&1, fn_names))
    |> Enum.uniq_by(fn {name, arity, _, _, _} -> {name, arity} end)
    |> Enum.map(fn {name, _arity, meta, _args, _body} ->
      build_diagnostic(file, AST.line(meta), name)
    end)
  end

  # Public `to_X/1` — `to_string`, `to_json`, `to_url`, `to_iodata`, etc.
  defp encoder_to_x_one?({name, 1, _meta, _args, _body}) do
    name_str = Atom.to_string(name)
    String.starts_with?(name_str, "to_") and name_str != "to_"
  end

  defp encoder_to_x_one?(_), do: false

  # Suppress when name is FP-filtered (external-API exact / external-service
  # prefix / lossy / stdlib / internal-projection) or when a local decoder
  # exists.
  defp suppressed?({name, _, _, _, _}, fn_names) do
    name_str = Atom.to_string(name)

    name_str in @fp_filtered_names or
      external_service_prefix?(name_str) or
      projection_suffix?(name_str) or
      has_decoder?(name_str, fn_names)
  end

  defp external_service_prefix?(name_str) do
    Enum.any?(@external_service_serializer_prefixes, &String.starts_with?(name_str, &1))
  end

  defp projection_suffix?(name_str) do
    Enum.any?(@projection_suffixes, &String.ends_with?(name_str, &1))
  end

  # `to_X` should have at least one of `from_X`, `parse_X`, `decode_X`
  # in the same module's public surface.
  defp has_decoder?("to_" <> suffix, fn_names) do
    Enum.any?(@decoder_prefixes, fn prefix -> MapSet.member?(fn_names, prefix <> suffix) end)
  end

  defp has_decoder?(_, _), do: false

  defp build_diagnostic(file, line, name) do
    Diagnostic.info("6.102",
      title: "Encoder without decoder",
      message:
        "`#{name}/1` is an encoder (`to_X`) but the module has no matching " <>
          "`from_X` / `parse_X` / `decode_X`. Encoders without decoders " <>
          "create one-way data flows that are hard to round-trip.",
      why:
        "When a module exposes `to_X` (a serializer) but no inverse, downstream " <>
          "code can produce values it can't read back. The bidirectional pair " <>
          "lets you property-test `decode(encode(x)) == x` — a strong invariant " <>
          "that catches whole classes of serialization bugs at design time. " <>
          "If round-tripping doesn't matter for this type, ignore the warning; " <>
          "if it does, defining the decoder NOW (even with a `not_implemented` " <>
          "raise) signals intent and pins the contract.",
      alternatives: [
        Fix.new(
          summary: "Add a matching decoder",
          detail:
            "Define `from_X/1`, `parse_X/1`, or `decode_X/1`. Add a property " <>
              "test asserting round-trip identity.",
          example: """
          ```elixir
          # before
          defmodule Email do
            def to_string(e), do: e.address
          end

          # after
          defmodule Email do
            def to_string(e), do: e.address
            def from_string(s), do: {:ok, %__MODULE__{address: s}}
          end
          ```
          """,
          applies_when: "The encoded form ever needs to be parsed back."
        ),
        Fix.new(
          summary: "Defines String.Chars / Inspect protocol instead",
          detail:
            "If `to_string` is for human-readable output (not data interchange), " <>
              "implement `String.Chars` or `Inspect` instead — those don't " <>
              "imply a round-trip contract.",
          applies_when: "The output is for display, not parseable interchange."
        )
      ],
      file: file,
      line: line
    )
  end
end
