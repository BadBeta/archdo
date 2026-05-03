defmodule Archdo.Rules.Module.BangInOkErrorFunction do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix, Naming}

  @impl true
  def id, do: "6.15"

  @impl true
  def description,
    do: "Functions returning ok/error tuples should not call bang functions that can raise"

  # Functions where bang calls are expected (setup, scripts, migrations)
  @bang_ok_contexts ~w(
    start_link init child_spec setup seed migrate rollback
  )a

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or seed_or_migration?(file) do
      []
    else
      find_bang_in_ok_error(file, ast)
    end
  end

  defp find_bang_in_ok_error(file, ast) do
    fns = AST.extract_functions(ast, :public)

    for {name, arity, meta, _args, body} <- fns,
        body != nil and
          name not in @bang_ok_contexts and
          not Naming.bang?(name) and
          returns_ok_error?(body) and
          contains_risky_bang?(body) do
      bangs = collect_bang_calls(body)
      build_diagnostic(file, name, arity, meta, bangs)
    end
  end

  # Function returns {:ok, _} or {:error, _} — the ok/error contract
  defp returns_ok_error?(body) do
    AST.contains?(body, fn
      {:ok, _} -> true
      {:{}, _, [{:__block__, _, [:ok]} | _]} -> true
      {:error, _} -> true
      {:{}, _, [{:__block__, _, [:error]} | _]} -> true
      _ -> false
    end)
  end

  # Body contains bang function calls (remote or local)
  defp contains_risky_bang?(body) do
    AST.contains?(body, fn
      {{:., _, [_, func]}, _, _} when is_atom(func) ->
        Naming.bang?(func) and not safe_bang?(func)

      {func, _, args} when is_atom(func) and is_list(args) ->
        Naming.bang?(func) and not safe_bang?(func)

      _ ->
        false
    end)
  end

  defp collect_bang_calls(body) do
    AST.find_all(body, fn
      {{:., _, [{:__aliases__, _, _mod}, func]}, _, _} when is_atom(func) ->
        Naming.bang?(func) and not safe_bang?(func)

      _ ->
        false
    end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, mod}, func]}, _, _} ->
      "#{Enum.join(mod, ".")}.#{func}"
    end)
    |> Enum.uniq()
    |> Enum.take(3)
  end

  # Bangs that are safe (don't represent failable operations)
  defp safe_bang?(func) do
    func in [
      # Struct constructors (always succeed with valid input)
      :struct!,
      # Map/Keyword access (programmer error, not runtime failure)
      :fetch!,
      # IO operations (side-effect bangs that are conventional)
      :puts!
    ]
  end

  defp seed_or_migration?(file) do
    String.contains?(file, "/seeds") or
      String.contains?(file, "/migrations/") or
      String.contains?(file, "/release.ex") or
      String.ends_with?(file, "_seeder.ex")
  end

  defp build_diagnostic(file, name, arity, meta, bangs) do
    bang_list = Enum.join(bangs, ", ")

    Diagnostic.info("6.15",
      title: "Bang call in ok/error function",
      message: "#{name}/#{arity} returns ok/error tuples but calls bang functions: #{bang_list}",
      why:
        "When a function establishes an ok/error contract (returns {:ok, _} or {:error, _}), " <>
          "callers expect failures to come back as {:error, reason}, not as raised exceptions. " <>
          "A bang call inside this function breaks that contract — the caller's `case` or `with` " <>
          "never sees the error branch because the bang raises before the function can return " <>
          "{:error, _}. The caller must add a try/rescue, defeating the purpose of the ok/error API.",
      alternatives: [
        Fix.new(
          summary: "Replace bang calls with non-bang equivalents",
          detail:
            "Use the non-bang version and propagate its error: " <>
              "`case Repo.insert(changeset) do {:ok, record} -> ...; {:error, cs} -> {:error, cs} end` " <>
              "or use `with {:ok, record} <- Repo.insert(changeset) do ... end`.",
          applies_when: "A non-bang alternative exists (check the module's docs)."
        ),
        Fix.new(
          summary: "Wrap the bang call in a rescue if no non-bang exists",
          detail:
            "If the called function only has a bang variant, wrap it: " <>
              "`try do {:ok, risky_call!()} rescue e -> {:error, Exception.message(e)} end`. " <>
              "But prefer finding or creating a non-bang wrapper.",
          applies_when: "No non-bang alternative is available."
        ),
        Fix.new(
          summary: "Convert this function to a bang function if callers expect it to raise",
          detail:
            "If callers actually want exceptions (scripts, seeds, known-good paths), rename " <>
              "the function to end with `!` and remove the ok/error wrapping.",
          applies_when: "The function is used in contexts where raising is acceptable."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.15"],
      context: %{
        function: "#{name}/#{arity}",
        bang_calls: bangs
      },
      file: file,
      line: AST.line(meta)
    )
  end
end
