defmodule Archdo.Rules.Module.PhantomTypeOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @validator_names ~w(validate parse build new from_string from_map create)a

  @impl true
  def id, do: "6.103"

  @impl true
  def description,
    do: "Smart constructor + struct consumer — phantom-type opportunity"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_phantom_opportunities(file, ast)
    end
  end

  defp find_phantom_opportunities(file, ast) do
    case has_defstruct?(ast) do
      true -> classify(file, ast)
      false -> []
    end
  end

  defp has_defstruct?(ast) do
    AST.contains?(ast, fn
      {:defstruct, _, _} -> true
      _ -> false
    end)
  end

  defp classify(file, ast) do
    fns = AST.extract_functions(ast, :public)

    has_validator = Enum.any?(fns, &smart_constructor?/1)
    has_consumer = Enum.any?(fns, &consumer?/1)

    case has_validator and has_consumer do
      true ->
        meta = first_def_meta(ast)
        [build_diagnostic(file, AST.line(meta))]

      false ->
        []
    end
  end

  # A smart constructor is named like one of @validator_names, with arity 1+,
  # and its body returns `{:ok, %__MODULE__{...}}` somewhere.
  defp smart_constructor?({name, arity, _meta, _args, body})
       when arity >= 1 do
    name in @validator_names and returns_self_ok_tuple?(body)
  end

  defp smart_constructor?(_), do: false

  defp returns_self_ok_tuple?(body) do
    AST.contains?(body, fn
      # `{:ok, %__MODULE__{...}}` raw 2-tuple
      {:ok, {:%, _, [{:__MODULE__, _, _}, _]}} -> true
      # literal-encoder-wrapped form of the same
      {:__block__, _, [{{:__block__, _, [:ok]}, {:%, _, [{:__MODULE__, _, _}, _]}}]} -> true
      _ -> false
    end)
  end

  # A consumer takes `%__MODULE__{...}` as an argument (in any clause).
  defp consumer?({name, _arity, _meta, args, _body}) when not is_nil(args) do
    name not in @validator_names and Enum.any?(args, &self_struct_arg?/1)
  end

  defp consumer?(_), do: false

  defp self_struct_arg?({:%, _, [{:__MODULE__, _, _}, _]}), do: true
  defp self_struct_arg?({:=, _, [{:%, _, [{:__MODULE__, _, _}, _]}, _]}), do: true
  defp self_struct_arg?(_), do: false

  defp first_def_meta(ast) do
    ast
    |> AST.find_all(fn
      {:def, _, _} -> true
      _ -> false
    end)
    |> List.first()
    |> case do
      {:def, meta, _} -> meta
      _ -> []
    end
  end

  defp build_diagnostic(file, line) do
    Diagnostic.info("6.103",
      title: "Phantom-type opportunity",
      message:
        "This module has a smart constructor (`validate`/`parse`/etc. " <>
          "returning `{:ok, %__MODULE__{}}`) AND functions that take " <>
          "`%__MODULE__{}` as input — phantom types would let the type " <>
          "system distinguish 'unvalidated' from 'validated' instances.",
      why:
        "When the same struct type is used both pre- and post-validation, " <>
          "downstream consumers can't tell at the type level whether their " <>
          "input has been through the validator. Splitting the struct into " <>
          "`%Email{}` (validated) vs `%UnverifiedEmail{}` (raw) makes the " <>
          "validation step observable in function signatures: `def domain " <>
          "(%Email{}) :: ...` is statically guaranteed to receive a " <>
          "validated instance because there's no other way to construct " <>
          "`%Email{}` than through the validator. This is the canonical " <>
          "Make-Illegal-States-Unrepresentable pattern.",
      alternatives: [
        Fix.new(
          summary: "Split into validated / unvalidated structs",
          detail:
            "Define a sibling module for the unvalidated form. The " <>
              "validator becomes the only path from one to the other.",
          example: """
          ```elixir
          defmodule UnverifiedEmail do
            defstruct [:raw]
          end

          defmodule Email do
            @enforce_keys [:address]
            defstruct [:address]

            def validate(%UnverifiedEmail{raw: r}) do
              case String.contains?(r, "@") do
                true -> {:ok, %__MODULE__{address: r}}
                false -> {:error, :invalid}
              end
            end

            def domain(%__MODULE__{address: a}) do
              [_, d] = String.split(a, "@")
              d
            end
          end
          ```
          """,
          applies_when:
            "The validation step is non-trivial and consumers should not " <>
              "accept raw input."
        ),
        Fix.new(
          summary: "Add a property test for round-trip identity",
          detail:
            "Even without splitting types, a property test asserting " <>
              "`{:ok, x} = validate(input); valid_invariant(x)` pins the " <>
              "validator's contract.",
          applies_when: "Splitting the type would be too invasive for the current API."
        )
      ],
      file: file,
      line: line
    )
  end
end
