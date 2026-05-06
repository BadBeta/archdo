defmodule Archdo.Rules.Module.EncoderWithoutDecoder do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @decoder_prefixes ~w(from_ parse_ decode_)

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
    |> Enum.reject(fn {name, _, _, _, _} -> has_decoder?(Atom.to_string(name), fn_names) end)
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
