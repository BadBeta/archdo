defmodule Archdo.Rules.Boundary.UnvalidatedParams do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @handle_event_callback :handle_event
  @handle_params_callback :handle_params
  @handler_arity 3

  @impl true
  def id, do: "1.14"

  @impl true
  def description,
    do: "Controller/LiveView actions should validate incoming params at the boundary"

  # Module prefixes that indicate schema/param validation
  @validation_modules ~w(
    Params Input Schema Changeset JSV OpenApiSpex
    NimbleOptions Vex Drops Tarams
  )

  @impl true
  def analyze(file, ast, _opts) do
    cond do
      AST.test_file?(file) -> []
      fallback_controller?(file) -> []
      AST.controller_file?(file) -> check_controller(file, ast)
      AST.live_view_file?(file) -> check_live_view(file, ast)
      true -> []
    end
  end

  defp check_controller(file, ast) do
    fns = AST.extract_functions(ast, :public)

    fns
    |> Enum.filter(fn {_name, arity, _, args, body} ->
      arity == 2 and has_params_arg?(args) and not has_validation?(body)
    end)
    |> Enum.map(fn {name, _, meta, _, _} ->
      build_diagnostic(file, name, 2, meta, :controller)
    end)
  end

  defp check_live_view(file, ast) do
    fns = AST.extract_functions(ast, :public)

    fns
    |> Enum.filter(fn {name, arity, _, _, _} ->
      (name == @handle_event_callback and arity == @handler_arity) or
        (name == @handle_params_callback and arity == @handler_arity)
    end)
    |> Enum.reject(fn {_name, _, _, _, body} -> has_validation?(body) end)
    |> Enum.map(fn {name, arity, meta, _, _} ->
      build_diagnostic(file, name, arity, meta, :live_view)
    end)
  end

  defp build_diagnostic(file, name, arity, meta, kind) do
    kind_label =
      case kind do
        :controller -> "Controller action"
        :live_view -> "LiveView callback"
      end

    Diagnostic.info("1.14",
      title: "Unvalidated params at boundary",
      message:
        "#{kind_label} #{name}/#{arity} accepts external params without visible validation",
      why:
        "Controller actions and LiveView callbacks are system boundaries — the first place external " <>
          "data enters the application. Passing raw params deeper into the domain without casting, " <>
          "validating, or schema-checking them means invalid data travels further before being caught, " <>
          "error messages become less actionable, and the domain layer must defend itself against " <>
          "arbitrary shapes. Validate at the boundary and pass clean data inward.",
      alternatives: [
        Fix.new(
          summary: "Validate with an Ecto changeset",
          detail:
            "Cast the params through a changeset (schema-backed or schemaless) before passing them to " <>
              "the context. The changeset documents the expected shape, casts types, and returns " <>
              "structured errors for the UI.\n\n" <>
              "```elixir\n" <>
              "def create(conn, params) do\n" <>
              "  case Accounts.create_user(params) do\n" <>
              "    {:ok, user} -> ...\n" <>
              "    {:error, changeset} -> ...\n" <>
              "  end\n" <>
              "end\n" <>
              "```",
          applies_when: "The params map to an Ecto schema or a known data shape."
        ),
        Fix.new(
          summary: "Validate with JSON Schema (JSV)",
          detail:
            "Define a JSON Schema for the expected input and validate with JSV. This is especially " <>
              "valuable for API endpoints where the schema can be shared with frontend teams and " <>
              "used in OpenAPI documentation.\n\n" <>
              "```elixir\n" <>
              "schema = %{type: :object, properties: %{name: %{type: :string}}, required: [:name]}\n" <>
              "root = JSV.build!(schema)\n" <>
              "{:ok, validated} = JSV.validate(params, root)\n" <>
              "```",
          applies_when: "The API contract is shared across teams or defined in OpenAPI."
        ),
        Fix.new(
          summary: "Extract and validate specific keys explicitly",
          detail:
            "At minimum, extract the keys you need with pattern matching or Map.take/2 so the " <>
              "action documents which params it expects. This is better than passing the raw params " <>
              "map through, even without full validation.",
          applies_when: "Simple actions where a full changeset or schema would be overkill."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#1.14"],
      context: %{function: "#{name}/#{arity}", kind: kind},
      file: file,
      line: AST.line(meta)
    )
  end

  # Check if a function argument list includes a raw params variable (not destructured)
  defp has_params_arg?(args) when is_list(args) do
    # Get the second argument (first is conn/socket)
    case Enum.at(args, 1) do
      # Raw variable: def action(conn, params) — no destructuring
      {name, _, nil} when is_atom(name) ->
        name_str = Atom.to_string(name)

        name_str in ~w(params attrs parameters body payload input) and
          not String.starts_with?(name_str, "_")

      # Destructured map: def action(conn, %{"id" => id}) — shows intent, skip
      {:%{}, _, pairs} when is_list(pairs) and pairs != [] ->
        false

      # Struct: def action(conn, %SomeStruct{}) — skip
      {:%, _, _} ->
        false

      # Bare underscore: def action(conn, _params) — skip
      {:_, _, _} ->
        false

      _ ->
        false
    end
  end

  defp has_params_arg?(_), do: false

  defp fallback_controller?(file) do
    String.contains?(file, "fallback")
  end

  # Check if a function body contains any validation call or context delegation
  defp has_validation?(nil), do: false

  defp has_validation?(body) do
    AST.contains?(body, fn
      # Remote call to a validation module: Module.changeset(...), Module.validate(...)
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, _} ->
        validation_module?(mod_parts) or validation_function?(func) or
          context_function?(func)

      # Local call to changeset/cast/validate
      {func, _, args} when is_atom(func) and is_list(args) ->
        validation_function?(func)

      # Pipe into changeset/cast/validate
      {:|>, _, [_, {func, _, _}]} when is_atom(func) ->
        validation_function?(func)

      _ ->
        false
    end)
  end

  defp validation_module?(mod_parts) when is_list(mod_parts) do
    last =
      mod_parts
      |> List.last()
      |> Atom.to_string()

    Enum.any?(@validation_modules, fn prefix ->
      String.contains?(last, prefix)
    end)
  end

  defp validation_function?(func) when is_atom(func) do
    func_str = Atom.to_string(func)

    func in [:cast, :changeset, :validate, :validate!, :apply_action, :apply_action!] or
      String.starts_with?(func_str, "validate_") or
      String.starts_with?(func_str, "cast_") or
      func_str in ~w(build_changeset create_changeset registration_changeset)
  end

  defp validation_function?(_), do: false

  # Context functions that accept params and validate internally
  defp context_function?(func) when is_atom(func) do
    func_str = Atom.to_string(func)

    String.starts_with?(func_str, "create_") or
      String.starts_with?(func_str, "update_") or
      String.starts_with?(func_str, "register") or
      String.starts_with?(func_str, "insert_") or
      String.starts_with?(func_str, "save_") or
      String.starts_with?(func_str, "submit_") or
      String.starts_with?(func_str, "sign_in") or
      String.starts_with?(func_str, "log_in") or
      func_str in ~w(create update register authenticate sign_up)
  end

  defp context_function?(_), do: false
end
