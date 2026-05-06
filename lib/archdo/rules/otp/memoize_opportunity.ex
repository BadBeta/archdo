defmodule Archdo.Rules.OTP.MemoizeOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "5.75"

  @impl true
  def description,
    do: "Expensive call on a constant input inside a building-block fn — memoize"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_memoize_opportunities(file, ast)
    end
  end

  defp find_memoize_opportunities(file, ast) do
    case building_block?(ast) do
      true -> collect_expensive_calls(file, ast)
      false -> []
    end
  end

  defp building_block?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:moduledoc, _, [doc]}]} -> moduledoc_marks_building_block?(doc)
      _ -> false
    end)
  end

  defp moduledoc_marks_building_block?(doc) do
    case Unwrap.string(doc) do
      s when is_binary(s) ->
        lower = String.downcase(s)
        String.contains?(lower, "building block") or String.contains?(lower, "building-block")

      _ ->
        false
    end
  end

  defp collect_expensive_calls(file, ast) do
    ast
    |> AST.extract_functions(:all)
    |> Enum.flat_map(fn {_name, _arity, _meta, _args, body} ->
      body
      |> AST.find_all(&expensive_constant_call?/1)
      |> Enum.map(fn node ->
        build_diagnostic(file, AST.line(call_meta(node)), describe(node))
      end)
    end)
  end

  defp call_meta({_, meta, _}), do: meta

  # Expensive function calls whose first arg is a literal — would produce
  # the same result on every invocation, so it's a cache candidate.
  defp expensive_constant_call?({{:., _, [{:__aliases__, _, [:Regex]}, op]}, _, [arg | _]})
       when op in [:compile!, :compile, :recompile!, :recompile] do
    literal_arg?(arg)
  end

  defp expensive_constant_call?({{:., _, [{:__aliases__, _, [:Jason]}, op]}, _, [arg | _]})
       when op in [:decode!, :decode] do
    literal_arg?(arg)
  end

  defp expensive_constant_call?({{:., _, [:crypto, :hash]}, _, [_alg, arg | _]}) do
    literal_arg?(arg)
  end

  defp expensive_constant_call?({{:., _, [{:__aliases__, _, [:DateTime]}, op]}, _, [arg | _]})
       when op in [:from_iso8601] do
    literal_arg?(arg)
  end

  defp expensive_constant_call?(
         {{:., _, [{:__aliases__, _, [:NaiveDateTime]}, op]}, _, [arg | _]}
       )
       when op in [:from_iso8601] do
    literal_arg?(arg)
  end

  defp expensive_constant_call?(_), do: false

  # Treat as literal: bare string / integer / atom, or their literal-encoder
  # wrapped forms.
  defp literal_arg?({:__block__, _, [v]}), do: is_binary(v) or is_atom(v) or is_integer(v)
  defp literal_arg?(v) when is_binary(v) or is_atom(v) or is_integer(v), do: true
  # `~s(...)` / `~S(...)` parse to `{:sigil_s, _, [...]}` etc. — also literals.
  defp literal_arg?({sigil, _, _}) when sigil in [:sigil_s, :sigil_S, :sigil_w, :sigil_W],
    do: true

  defp literal_arg?(_), do: false

  defp describe({{:., _, [{:__aliases__, _, [mod]}, op]}, _, _}),
    do: "#{mod}.#{op}"

  defp describe({{:., _, [:crypto, op]}, _, _}), do: ":crypto.#{op}"
  defp describe(_), do: "expensive call"

  defp build_diagnostic(file, line, kind) do
    Diagnostic.info("5.75",
      title: "Memoize opportunity",
      message:
        "`#{kind}` is called inside a function body with a constant argument — " <>
          "the result is the same on every call. Cache it.",
      why:
        "Compiling a regex, decoding a JSON string, hashing a constant, or " <>
          "parsing a fixed ISO8601 string each take measurable time. Doing " <>
          "this work inside a hot function on every call wastes CPU. Move " <>
          "it to a module attribute (compile-time), `:persistent_term` " <>
          "(boot-time, read-mostly), or an ETS-backed memoize cache " <>
          "(runtime, mutable). For pure building blocks, a module attribute " <>
          "is the simplest correct answer.",
      alternatives: [
        Fix.new(
          summary: "Hoist to a module attribute",
          detail:
            "Compile/decode/hash once at compile time, then reference the " <>
              "attribute from the function body.",
          example: """
          ```elixir
          # before
          def valid?(input) do
            regex = Regex.compile!("^[a-z]+\$")
            Regex.match?(regex, input)
          end

          # after
          @valid_re Regex.compile!("^[a-z]+\$")
          def valid?(input), do: Regex.match?(@valid_re, input)
          ```
          """,
          applies_when:
            "The input is a literal string and Elixir can evaluate it at compile time."
        ),
        Fix.new(
          summary: "Use `:persistent_term` for boot-time large values",
          detail:
            "If the value is large (compiled NimbleOptions schema, big " <>
              "decoded JSON), `:persistent_term.put/2` at boot is faster " <>
              "than reloading per-call.",
          applies_when:
            "The value is large and changes infrequently; reads outpace writes by 1000:1+."
        )
      ],
      file: file,
      line: line
    )
  end
end
