defmodule Archdo.Rules.Module.RemovedMixConfig do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "3.7"

  @impl true
  def description,
    do:
      "Use of removed `Mix.Config` API — replaced by `Config` (import Config) " <>
        "in Elixir 1.9, removed entirely in 1.13"

  @impl true
  def analyze(file, ast, _opts) do
    case config_file?(file) do
      true -> find_mix_config_uses(file, ast)
      false -> []
    end
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatch on path
  # shape. Match config/*.exs at the project root or any
  # apps/<child>/config/*.exs in umbrellas. Skip _build/ and deps/.
  defp config_file?(file) do
    cond do
      build_artifact?(file) -> false
      String.starts_with?(file, "config/") -> true
      String.contains?(file, "/config/") -> not under_lib_or_test?(file)
      true -> false
    end
  end

  defp build_artifact?(file) do
    String.starts_with?(file, "_build/") or String.contains?(file, "/_build/") or
      String.starts_with?(file, "deps/") or String.contains?(file, "/deps/")
  end

  defp under_lib_or_test?(file) do
    segs = Path.split(file)
    Enum.any?(["lib", "test"], &(&1 in segs))
  end

  defp find_mix_config_uses(file, ast) do
    {_, hits} = Macro.prewalk(ast, [], fn node, acc -> visit(node, acc, file) end)
    Enum.reverse(hits)
  end

  # §§ elixir-implementing: §5.2 — pattern match in function head.
  # Two AST shapes for the removed API:
  #
  #   use Mix.Config       → {:use,    _, [{:__aliases__, _, [:Mix, :Config]}]}
  #   import Mix.Config    → {:import, _, [{:__aliases__, _, [:Mix, :Config]}]}
  defp visit(
         {kind, meta, [{:__aliases__, _, [:Mix, :Config]} | _]} = node,
         acc,
         file
       )
       when kind in [:use, :import] do
    {node, [build_diagnostic(file, kind, meta) | acc]}
  end

  defp visit(node, acc, _file), do: {node, acc}

  defp build_diagnostic(file, kind, meta) do
    Diagnostic.error("3.7",
      title: "`#{kind} Mix.Config` — removed API",
      message:
        "`Mix.Config` was deprecated in Elixir 1.9 and removed entirely. Modern " <>
          "Elixir uses the `Config` module — `import Config` at the top of every " <>
          "config/*.exs file, then `config_env()` instead of `Mix.env()`.",
      why:
        "`Mix.Config` only existed because config files used to be evaluated " <>
          "inside Mix's own module loader. Since Elixir 1.9, `config/*.exs` is " <>
          "evaluated by the standalone `Config` module so the same files work " <>
          "in Mix, releases, and external tooling. On Elixir 1.13+ the old " <>
          "module is gone — `use Mix.Config` raises `UndefinedFunctionError` at " <>
          "config load time, before the application even starts. (Compatibility, " <>
          "Toolchain Modernization)",
      alternatives: [
        Fix.new(
          summary: "Replace `#{kind} Mix.Config` with `import Config`",
          detail:
            "# BEFORE:\n" <>
              "#{kind} Mix.Config\n\n" <>
              "config :my_app, key: value\n\n" <>
              "# AFTER:\n" <>
              "import Config\n\n" <>
              "config :my_app, key: value\n\n" <>
              "If the file uses `Mix.env()`, also replace it with `config_env()` " <>
              "(macro provided by `Config`, available in 1.11+). The `config_*` " <>
              "calls themselves are unchanged.",
          applies_when: "Always — `Config` is a drop-in replacement."
        )
      ],
      references: [
        "ARCHITECTURE_RULES.md#3.7",
        "https://hexdocs.pm/elixir/Config.html",
        "elixir-implementing/SKILL.md#10.5"
      ],
      context: %{kind: kind},
      file: file,
      line: AST.line(meta)
    )
  end
end
