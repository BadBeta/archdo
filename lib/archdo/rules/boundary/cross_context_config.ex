defmodule Archdo.Rules.Boundary.CrossContextConfig do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.32"

  @impl true
  def description, do: "Module reads another context's Application config keys"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) or config_file?(file) do
      true -> []
      false -> find_cross_context_config(file, ast)
    end
  end

  defp find_cross_context_config(file, ast) do
    own_context = extract_context(file)

    case own_context do
      nil -> []
      ctx -> find_foreign_config_reads(file, ast, ctx)
    end
  end

  defp find_foreign_config_reads(file, ast, own_context) do
    Enum.map(AST.find_all(ast, fn
      # Application.get_env(:other_app, OtherContext.Key)
      {{:., _, [{:__aliases__, _, [:Application]}, func]}, _, [_app, {:__aliases__, _, aliases} | _]}
      when func in [:get_env, :fetch_env, :fetch_env!, :compile_env, :compile_env!] ->
        foreign_context?(aliases, own_context)

      # Application.get_env(:app, :other_context_key)
      # Hard to detect without naming conventions — skip

      _ ->
        false
    end), fn {_, meta, _} ->
      build_diagnostic(file, AST.line(meta), own_context)
    end)
  end

  defp foreign_context?(aliases, own_context) when is_list(aliases) and length(aliases) >= 2 do
    context_atom = Enum.at(aliases, 1)

    case is_atom(context_atom) do
      true ->
        foreign = Atom.to_string(context_atom)
        foreign != own_context

      false ->
        false
    end
  end

  defp foreign_context?(_, _), do: false

  defp extract_context(file) do
    case Regex.run(~r{lib/[^/]+/([^/]+)/}, file) do
      [_, context] -> Macro.camelize(context)
      _ -> nil
    end
  end

  defp config_file?(file) do
    String.contains?(file, "/config/") or
      String.ends_with?(file, "/application.ex") or
      String.ends_with?(file, "mix.exs")
  end

  defp build_diagnostic(file, line, own_context) do
    Diagnostic.info("1.32",
      title: "Cross-context config read",
      message: "#{own_context} reads Application config for another context's module",
      why:
        "Reading another context's configuration creates hidden coupling. " <>
          "If the config key changes, the reading context breaks silently. " <>
          "Each context should own its own configuration and expose " <>
          "what others need through its public API.",
      alternatives: [
        Fix.new(
          summary: "Ask the owning context for the value",
          detail:
            "Instead of `Application.get_env(:app, OtherCtx.Config)`, call " <>
              "`OtherCtx.config_value()` — the owning context wraps the config read.",
          applies_when: "The config belongs to another bounded context."
        )
      ],
      file: file,
      line: line
    )
  end
end
