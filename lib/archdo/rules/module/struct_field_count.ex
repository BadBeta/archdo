defmodule Archdo.Rules.Module.StructFieldCount do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @warn_threshold 20
  @error_threshold 32

  @impl true
  def id, do: "6.3"

  @impl true
  def description, do: "Struct field count limit"

  @impl true
  def analyze(file, ast, _opts) do
    find_structs(file, ast)
  end

  defp find_structs(file, ast) do
    {_, results} =
      Macro.prewalk(ast, [], fn
        {:defstruct, meta, [fields]} = node, acc when is_list(fields) ->
          count = count_fields(fields)
          diagnostics = check_count(file, count, AST.line(meta), find_module_name(ast))
          {node, diagnostics ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(results)
  end

  defp count_fields(fields) do
    Enum.count(fields, fn
      {_key, _default} -> true
      key when is_atom(key) -> true
      _ -> false
    end)
  end

  defp check_count(file, count, line, module_name) do
    cond do
      count >= @error_threshold ->
        [field_count_diag(file, line, module_name, count, :error)]

      count >= @warn_threshold ->
        [field_count_diag(file, line, module_name, count, :warning)]

      true ->
        []
    end
  end

  defp field_count_diag(file, line, module_name, count, severity) do
    builder = if severity == :error, do: &Diagnostic.error/2, else: &Diagnostic.warning/2

    builder.("6.3",
      title: "Struct with too many fields",
      message: "#{module_name} defstruct has #{count} fields",
      why:
        "Erlang maps switch from a flat layout to a hash-array-mapped trie at 32 keys. Up to 32 fields " <>
          "they're cheap to copy and pattern-match; above 32, every field access and update goes through the " <>
          "tree, costing performance and memory. Beyond performance, a struct with more than ~20 fields is " <>
          "almost always describing several distinct concepts that wandered into one record.",
      alternatives: [
        Fix.new(
          summary: "Decompose into smaller embedded structs",
          detail:
            "Identify groups of related fields (`shipping_*`, `billing_*`, `address_*`) and lift each group " <>
              "into its own embedded struct. Replace the flat fields with one field per group. The original " <>
              "struct stays under 20 fields and the sub-structs each describe a coherent concept.",
          example: """
          ```elixir
          # before
          defstruct [:name, :ship_street, :ship_city, :ship_zip, :bill_street, :bill_city, :bill_zip, ...]

          # after
          defstruct [:name, :shipping, :billing]
          # where Shipping/Billing are their own structs
          ```
          """,
          applies_when: "The fields cluster into named groups."
        ),
        Fix.new(
          summary: "Split the struct entirely if it's modeling multiple concepts",
          detail:
            "If the struct lumps unrelated concepts (an Order with line items, payment, customer, shipping " <>
              "and audit metadata), split it into separate structs and reference each by id. Each struct now " <>
              "represents one concept.",
          applies_when: "The struct mixes unrelated domain concepts."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.3"],
      context: %{
        module: module_name,
        field_count: count,
        threshold_warn: @warn_threshold,
        threshold_error: @error_threshold
      },
      file: file,
      line: line
    )
  end

  defp find_module_name(ast) do
    {_, name} =
      Macro.prewalk(ast, "Unknown", fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, _acc ->
          {node, Module.concat(aliases) |> Atom.to_string() |> String.replace("Elixir.", "")}

        node, acc ->
          {node, acc}
      end)

    name
  end
end
