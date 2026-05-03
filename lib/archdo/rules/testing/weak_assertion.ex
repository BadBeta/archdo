defmodule Archdo.Rules.Testing.WeakAssertion do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "7.18"

  @impl true
  def description,
    do: "Weak assertion — assert function() without pattern match loses error details"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      false -> []
      true -> find_weak_assertions(file, ast)
    end
  end

  defp find_weak_assertions(file, ast) do
    AST.find_all(ast, fn
      # assert Module.function(args) — call result only checked for truthiness
      {:assert, _, [{{:., _, _}, _, _}]} ->
        true

      # assert function(args) — local call only checked for truthiness
      # Exclude: pattern match (=), comparison (==, !=), guards (is_*), match?
      {:assert, _, [{func, _, args}]}
      when is_atom(func) and is_list(args) ->
        func not in [
          :match?,
          :is_struct,
          :=,
          :==,
          :!=,
          :===,
          :!==,
          :>,
          :<,
          :>=,
          :<=,
          true,
          false,
          nil,
          :in,
          :not,
          :and,
          :or
        ] and
          not String.starts_with?(Atom.to_string(func), "is_")

      _ ->
        false
    end)
    |> then(fn nodes ->
      # Allow assert Enum.any?(...) — predicate functions are fine
      for {:assert, meta, [call]} <- nodes,
          not predicate_call?(call) do
        {meta, call}
      end
    end)
    |> Enum.map(fn {meta, call} ->
      call_str = extract_call_name(call)

      Diagnostic.info("7.18",
        title: "Weak assertion",
        message: "assert #{call_str} — only checks truthiness, not the return shape",
        why:
          "Asserting a function call without pattern matching means {:error, reason} passes " <>
            "(it's truthy), :ok and {:ok, nil} pass (truthy), and only nil/false fail. " <>
            "Pattern matching `assert {:ok, user} = Accounts.create(attrs)` catches shape " <>
            "mismatches immediately and binds the result for further assertions.",
        alternatives: [
          Fix.new(
            summary: "Pattern match the expected return shape",
            detail:
              "`assert {:ok, user} = Accounts.create_user(attrs)` — fails if the function " <>
                "returns {:error, _} or any other shape. Also binds `user` for further checks.",
            applies_when: "The function returns tagged tuples ({:ok, _}/{:error, _})."
          ),
          Fix.new(
            summary: "Use a specific assertion if checking a property",
            detail:
              "`assert user.active == true` or `assert length(list) == 3` instead of " <>
                "`assert is_active(user)` — specific assertions give better failure messages.",
            applies_when: "You're checking a specific property, not a return value."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#7.18"],
        context: %{call: call_str},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp predicate_call?({{:., _, [_, func]}, _, _}) when is_atom(func) do
    func
    |> Atom.to_string()
    |> String.ends_with?("?")
  end

  defp predicate_call?({func, _, _}) when is_atom(func) do
    func
    |> Atom.to_string()
    |> String.ends_with?("?")
  end

  defp predicate_call?(_), do: false

  defp extract_call_name({{:., _, [{:__aliases__, _, mod}, func]}, _, _}) do
    "#{Enum.join(mod, ".")}.#{func}(...)"
  end

  defp extract_call_name({func, _, _}) when is_atom(func), do: "#{func}(...)"
  defp extract_call_name(_), do: "function(...)"
end
