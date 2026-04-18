defmodule Archdo.Rules.Boundary.ImportBreadth do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.5"

  @impl true
  def description, do: "Minimal coupling at module interfaces — import breadth"

  @tolerated_imports [
    "Ecto.Query",
    "Ecto.Changeset",
    "Phoenix.LiveView",
    "Phoenix.Component",
    "Phoenix.HTML",
    "Phoenix.Controller",
    "Phoenix.LiveView.Router",
    "Plug.Conn",
    "Bitwise"
  ]

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) or phoenix_macro_file?(file) do
      []
    else
      find_broad_imports(file, ast) ++ find_coupling_fanout(file, ast)
    end
  end

  defp find_broad_imports(file, ast) do
    AST.find_all(ast, fn
      {:import, _meta, [{:__aliases__, _, _aliases} | _]} -> true
      _ -> false
    end)
    |> Enum.filter(fn {:import, _meta, [{:__aliases__, _, aliases} | opts]} ->
      case AST.safe_concat(aliases) do
        nil -> false
        mod ->
          target = AST.module_name(mod)
          no_only_clause?(opts) and not tolerated_import?(target)
      end
    end)
    |> Enum.map(fn {:import, meta, [{:__aliases__, _, aliases} | _]} ->
      target = Enum.join(aliases, ".")

      Diagnostic.warning("4.5",
        title: "Broad import without :only clause",
        message: "import #{target} without `:only` — every public function in #{target} is in scope",
        why:
          "An unrestricted import dumps every public function from the imported module into the current " <>
            "module's namespace. The reader can't tell where any function comes from without grepping, the " <>
            "module is implicitly coupled to the entire surface (so renames anywhere break this file), and " <>
            "Dialyzer/the compiler can't help disambiguate name clashes.",
        alternatives: [
          Fix.new(
            summary: "Switch to `alias` and call functions through the alias",
            detail:
              "`alias #{target}` keeps the namespace explicit at the call site (`#{Enum.at(aliases, -1)}.fun(...)`) " <>
                "and the file only depends on the functions you actually call. This is the right default " <>
                "for almost everything.",
            applies_when: "You only call a few functions from the module."
          ),
          Fix.new(
            summary: "Use `import #{target}, only: [fun: arity, ...]`",
            detail:
              "If you really want unqualified calls (e.g. for DSL helpers), list the specific functions in " <>
                "an `:only` clause. The intent is documented and Dialyzer can resolve them.",
            applies_when: "Unqualified syntax matters and the set of functions is small."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#4.5"],
        context: %{import: target},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  defp find_coupling_fanout(file, ast) do
    {_, aliases} =
      Macro.prewalk(ast, [], fn
        {:alias, _meta, [{:__aliases__, _, aliases} | _]} = node, acc ->
          case AST.safe_concat(aliases) do
            nil -> {node, acc}
            mod -> {node, [AST.module_name(mod) | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    alias_count = aliases |> Enum.uniq() |> length()

    if alias_count > 10 do
      module_name = extract_module_name(ast)

      [
        Diagnostic.info("4.5",
          title: "High coupling fan-out",
          message: "#{module_name} aliases #{alias_count} other modules",
          why:
            "A module that aliases more than ~10 collaborators is doing the work of several modules — every " <>
              "function it calls is a thread connecting it to another part of the system. High alias counts " <>
              "correlate with low cohesion (the module spans multiple concerns) and high change-amplification " <>
              "(any of those collaborators changing forces edits here).",
          alternatives: [
            Fix.new(
              summary: "Split the module along its natural seams",
              detail:
                "Look for clusters of aliases that get used together — they often indicate separate " <>
                  "responsibilities. Extract each cluster into its own module so each new module aliases only " <>
                  "what it actually needs.",
              applies_when: "The aliases cluster into distinct responsibilities."
            ),
            Fix.new(
              summary: "Introduce a context module that aggregates the aliases",
              detail:
                "If many aliases are sub-modules of one context, replace them with a single alias to the " <>
                  "context's public API and call functions through it. The fan-out concentrates onto one boundary.",
              applies_when: "Most aliases are sub-modules of the same context."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#4.5"],
          context: %{module: module_name, alias_count: alias_count},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp no_only_clause?([]), do: true

  defp no_only_clause?([opts]) when is_list(opts) do
    not Keyword.has_key?(opts, :only)
  end

  defp no_only_clause?(_), do: true

  defp tolerated_import?(target) do
    Enum.any?(@tolerated_imports, &(target == &1)) or
      # Tolerate Telemetry.Metrics — standard Phoenix telemetry pattern
      target == "Telemetry.Metrics" or
      # Tolerate any import ending in CoreComponents — Phoenix convention
      String.ends_with?(target, "CoreComponents")
  end

  # Phoenix _web.ex files contain quote blocks defining macros for controllers,
  # live views, etc. Imports inside these are framework convention, not coupling.
  defp phoenix_macro_file?(file) do
    String.ends_with?(file, "_web.ex") or String.ends_with?(file, "_web/components.ex")
  end

  defp extract_module_name(ast), do: Archdo.AST.extract_module_name(ast)

end
