defmodule Archdo.Rules.Module.NaturalSeams do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # If a module has N+ public functions sharing the same prefix,
  # that prefix is a natural seam for extraction.
  @min_prefix_group 4

  @impl true
  def id, do: "4.14"

  @impl true
  def description, do: "Natural seams — public functions cluster by prefix, suggesting sub-modules"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      check_prefix_clusters(file, ast)
    end
  end

  defp check_prefix_clusters(file, ast) do
    fns = AST.extract_functions(ast, :public)

    # Extract prefixes (first word) from function names
    prefix_groups =
      fns
      |> Enum.map(fn {name, _, _, _, _} -> {name, extract_prefix(name)} end)
      |> Enum.reject(fn {_, prefix} -> is_nil(prefix) end)
      |> Enum.group_by(fn {_, prefix} -> prefix end, fn {name, _} -> name end)
      |> Enum.filter(fn {_prefix, names} -> length(names) >= @min_prefix_group end)

    if length(prefix_groups) >= 2 do
      module_name = AST.extract_module_name(ast)

      [
        Diagnostic.info("4.14",
          title: "Natural seams in module",
          message:
            "#{module_name} has #{length(prefix_groups)} function prefix clusters: #{format_clusters(prefix_groups)}",
          why:
            "When public functions cluster around 4+ shared prefixes (`user_create`, `user_list`, `user_delete`, " <>
              "`user_update`...), the prefix is doing the work of a sub-module name. The repetition is " <>
              "telling you the module wants to be split: each prefix represents a coherent sub-responsibility " <>
              "and pulling it out makes the code easier to find, easier to test, and easier to grow.",
          alternatives: [
            Fix.new(
              summary: "Extract each prefix cluster into its own sub-module",
              detail:
                "For each prefix `foo_*`, create a `#{module_name}.Foo` module containing the related functions " <>
                  "(usually with the prefix dropped). The original module either disappears or becomes a thin " <>
                  "facade that delegates to the sub-modules.",
              example: """
              ```elixir
              # before
              def user_create(...)
              def user_list(...)
              def user_delete(...)

              # after — in #{module_name}.User
              def create(...)
              def list(...)
              def delete(...)
              ```
              """,
              applies_when: "The clusters represent distinct sub-responsibilities."
            ),
            Fix.new(
              summary: "Keep them together if the prefix is just a naming convention",
              detail:
                "Sometimes the prefix exists for grep-friendliness (`enq_*`, `dec_*` in low-level codecs) and " <>
                  "the functions form a tight unit. Add to freeze if splitting would create artificial barriers.",
              applies_when: "The functions are truly tightly coupled."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#4.14"],
          context: %{
            module: module_name,
            cluster_count: length(prefix_groups),
            clusters: Enum.map(prefix_groups, fn {p, ns} -> %{prefix: to_string(p), count: length(ns)} end)
          },
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp extract_prefix(name) when is_atom(name) do
    case String.split(Atom.to_string(name), "_", parts: 2) do
      [prefix, _] when byte_size(prefix) >= 3 -> prefix
      _ -> nil
    end
  end

  # Macro-generated function names (unquote, etc.) are not real prefixes
  defp extract_prefix(_), do: nil

  defp format_clusters(groups) do
    groups
    |> Enum.map_join(", ", fn {prefix, names} -> "#{prefix}_* (#{length(names)})" end)
  end

end
