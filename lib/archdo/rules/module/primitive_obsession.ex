defmodule Archdo.Rules.Module.PrimitiveObsession do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # Names that strongly suggest the parameter should be a typed concept
  @typed_concepts ~w(email phone url uri token amount price money currency
                      timestamp date time duration weight distance volume
                      latitude longitude coordinate address postal_code zip)

  # Minimum unique typed concepts before flagging
  @threshold 3

  @impl true
  def id, do: "4.12"

  @impl true
  def description, do: "Primitive obsession — many string params that should be typed structs"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_primitive_obsession(file, ast)
    end
  end

  defp find_primitive_obsession(file, ast) do
    fns = AST.extract_functions(ast, :public)

    fns
    |> Enum.flat_map(fn {name, arity, meta, args, _body} ->
      typed_arg_names = collect_typed_arg_names(args)

      if length(typed_arg_names) >= @threshold do
        [
          Diagnostic.info("4.12",
            title: "Primitive obsession",
            message:
              "#{name}/#{arity} takes #{length(typed_arg_names)} primitive params for typed concepts: #{Enum.join(typed_arg_names, ", ")}",
            why:
              "Passing related primitive values (`email`, `phone`, `address`, `latitude`, `longitude`) as " <>
                "separate arguments forces every caller to know the order, lose type safety, and reimplement " <>
                "validation. Modeling them as structs (Email, PhoneNumber, GeoPoint) gives you a single value " <>
                "that carries its validation rules and can't be silently mis-ordered at the call site.",
            alternatives: [
              Fix.new(
                summary: "Introduce a struct for each typed concept",
                detail:
                  "Create small modules (`MyApp.Email`, `MyApp.PhoneNumber`) with `@enforce_keys`, a constructor " <>
                    "that validates the input, and helper functions. Replace the primitive parameter with the struct.",
                example: """
                ```elixir
                defmodule MyApp.Email do
                  @enforce_keys [:value]
                  defstruct [:value]

                  def new(string) when is_binary(string) do
                    if String.contains?(string, "@"), do: {:ok, %__MODULE__{value: string}}, else: {:error, :invalid}
                  end
                end
                ```
                """,
                applies_when: "The concept has its own validation or invariants."
              ),
              Fix.new(
                summary: "Group related parameters into a single struct",
                detail:
                  "Sometimes the parameters aren't separate concepts but parts of one concept (latitude + " <>
                    "longitude → GeoPoint, street + city + zip → Address). Replace the multi-arg list with " <>
                    "the grouping struct.",
                applies_when: "Multiple parameters describe one larger concept."
              )
            ],
            references: ["ARCHITECTURE_RULES.md#4.12"],
            context: %{
              function: "#{name}/#{arity}",
              concept_args: typed_arg_names
            },
            file: file,
            line: AST.line(meta)
          )
        ]
      else
        []
      end
    end)
  end

  defp collect_typed_arg_names(args) when is_list(args) do
    args
    |> Enum.map(&arg_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn name ->
      Enum.any?(@typed_concepts, fn concept -> name =~ concept end)
    end)
    |> Enum.uniq()
  end

  defp collect_typed_arg_names(_), do: []

  defp arg_name({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    Atom.to_string(name)
  end

  defp arg_name({:\\, _, [{name, _, _} | _]}) when is_atom(name), do: Atom.to_string(name)

  defp arg_name(_), do: nil
end
