defmodule Archdo.Compiled do
  @moduledoc false

  # Compilation tracer-based cross-reference analysis.
  #
  # When a project is compiled with Archdo's tracer enabled, we capture
  # every remote function call, import, struct expansion, and module
  # definition. This gives us ground-truth data that AST-only analysis
  # can't provide:
  #
  #   - Macro-injected functions (visible after expansion)
  #   - Resolved imports (which module each unqualified call targets)
  #   - Protocol dispatch targets
  #   - Dead code detection (exported functions never called)
  #   - Complete behaviour callback lists (including @optional_callbacks)

  alias Archdo.Compiled.Graph

  @doc """
  Analyze a project directory by reading compiled beam files and building
  a complete interaction graph.

  Returns `{:ok, %Compiled.Graph{}}` or `{:error, reason}`.

  The graph contains:
    - `:modules` — map of module => %{exports, behaviours, struct_fields, callback_fns}
    - `:calls` — list of %{caller: mfa, callee: mfa, line: N}
    - `:calls_by_caller` — indexed by caller MFA
    - `:calls_by_callee` — indexed by callee MFA
    - `:calls_by_module` — indexed by caller module
    - `:protocol_impls` — protocol => [impl_modules]
    - `:struct_expansions` — struct usage tracking
  """
  @spec analyze(String.t()) :: {:ok, Graph.t()} | {:error, String.t()}
  def analyze(project_path) do
    case find_beam_dir(project_path) do
      nil ->
        {:error, "No compiled beam files found. Run `mix compile` in the target project first."}

      dir ->
        app_name = detect_app_name(project_path)
        graph = Graph.build(dir)
        {:ok, %{graph | app_name: app_name, beam_dir: dir}}
    end
  end

  # --- I/O Boundary (impure shell) ---

  defp find_beam_dir(project_path) do
    build_dir = Path.join(project_path, "_build")

    case detect_app_name(project_path) do
      nil ->
        nil

      app_name ->
        # Look for _build/ENV/lib/APP/ebin — try dev first, then prod
        ["dev", "prod", "test"]
        |> Enum.find_value(fn env ->
          dir = Path.join([build_dir, env, "lib", app_name, "ebin"])

          case File.dir?(dir) and Path.wildcard(Path.join(dir, "*.beam")) != [] do
            true -> dir
            false -> nil
          end
        end)
    end
  end

  defp detect_app_name(project_path) do
    mix_file = Path.join(project_path, "mix.exs")

    case File.read(mix_file) do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
