defmodule Archdo.Mcp.Tools.Stats do
  @moduledoc false

  def name, do: "archdo_stats"

  def description do
    "Project statistics — files, lines of code, modules, functions (public/private), " <>
      "tests, GenServers, supervisors, Ecto schemas, structs, protocols, behaviours, " <>
      "@spec coverage, @moduledoc coverage. Like tokei but Elixir-aware."
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "paths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Paths to analyze. Default: [\"lib\"]."
        }
      },
      "additionalProperties" => false
    }
  end

  def call(args) when is_map(args) do
    paths = Map.get(args, "paths", ["lib"])
    stats = Archdo.Stats.collect(paths)

    %{
      source: format_section(stats.lib),
      tests: format_section(stats.test),
      totals: %{
        files: stats.total.files,
        code_lines: stats.total.code_lines,
        modules: stats.total.modules,
        functions: stats.total.public_fns + stats.total.private_fns,
        tests: stats.total.tests
      },
      contexts:
        Enum.map(stats.contexts, fn ctx ->
          %{
            name: ctx.name,
            modules: ctx.modules,
            cohesion: ctx.cohesion,
            coupling: ctx.coupling,
            leak_calls: ctx.leak_calls
          }
        end)
    }
  end

  defp format_section(s) do
    %{
      files: s.files,
      lines: s.lines,
      code_lines: s.code_lines,
      comment_lines: s.comment_lines,
      blank_lines: s.blank_lines,
      modules: s.modules,
      public_fns: s.public_fns,
      private_fns: s.private_fns,
      macros: s.macros,
      tests: s.tests,
      genservers: s.genservers,
      supervisors: s.supervisors,
      schemas: s.schemas,
      structs: s.structs,
      protocols: s.protocols,
      behaviours_defined: s.behaviours_defined,
      behaviours_used: s.behaviours_implemented,
      specs: s.specs,
      moduledocs: s.moduledocs,
      avg_module_lines: s.avg_module_lines,
      largest_file: elem(s.largest_module, 0),
      largest_file_lines: elem(s.largest_module, 1)
    }
  end
end
