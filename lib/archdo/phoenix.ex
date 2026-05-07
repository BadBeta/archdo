defmodule Archdo.Phoenix do
  @moduledoc """
  Phoenix-aware file-layer classifier.

  Single context module owning Phoenix-aware file classification.
  Boundary rules (1.26, 6.10, etc.) used to each re-derive "is this
  an application supervisor / Mix task / live view?" via path
  heuristics scattered across modules; centralizing here gives one
  registry that every rule consumes via `opts[:phoenix]`.

  Public API for rule writers — every rule that branches on
  Phoenix layer should call `classify_file/2` rather than rolling
  its own path-and-AST inspection.
  """

  alias Archdo.AST

  @type layer ::
          :application_root
          | :web
          | :live_view
          | :component
          | :controller
          | :router
          | :context
          | :schema
          | :migration
          | :operational
          | :test
          | :other

  @type classification :: %{
          layer: layer(),
          uses: %{module() => [term()]},
          embed_templates: [String.t()],
          defimpl_callbacks: MapSet.t({atom(), arity()}),
          impl_callbacks: MapSet.t({atom(), arity()})
        }

  @doc """
  Classify a Phoenix/Ecto file by its architectural layer.

  Reads `use` declarations and path conventions to decide whether a file is
  a LiveView, controller, router, context, operational tooling, etc. Rules
  consume `:layer` to decide whether to skip a file (e.g. application
  supervisors and Mix tasks legitimately reach into many layers).
  """
  @spec classify_file(Path.t(), Macro.t()) :: classification()
  def classify_file(path, ast) do
    uses = collect_uses(ast)

    %{
      layer: detect_layer(path, uses),
      uses: uses,
      embed_templates: collect_embed_templates(ast),
      defimpl_callbacks: AST.defimpl_callbacks(ast),
      impl_callbacks: AST.impl_callbacks(ast)
    }
  end

  @doc """
  True when the layer is one whose code legitimately bridges architectural
  boundaries (operational tooling, application root, tests). Boundary rules
  should typically skip these files.
  """
  @spec operational?(classification() | %{layer: layer()}) :: boolean()
  def operational?(%{layer: layer}) do
    layer in [:operational, :test, :application_root]
  end

  @doc """
  Resolve a Phoenix classification from rule opts, falling back to
  `classify_file/2` when the caller didn't pre-compute it. Used by
  rules that accept either a project-wide classification map (passed
  in opts under `:phoenix` to avoid recomputing per-file) or compute
  their own on demand.
  """
  @spec resolve_classification(keyword(), String.t(), Macro.t()) ::
          classification() | %{layer: layer()}
  def resolve_classification(opts, file, ast) do
    case Keyword.get(opts, :phoenix) do
      %{layer: _} = c -> c
      _ -> classify_file(file, ast)
    end
  end

  @doc """
  Extract the context segment from a `lib/<app>/<context>/...` file path.
  Returns the camelized context name (`"Accounts"`, `"OrderManagement"`)
  or `nil` if the path doesn't match the standard nested layout.

  Used by boundary rules that need to attribute a file to its owning
  context for cross-context call detection.
  """
  @spec context_for_file(String.t()) :: String.t() | nil
  def context_for_file(file) do
    case Regex.run(~r{lib/[^/]+/([^/]+)/}, file) do
      [_, context] -> Macro.camelize(context)
      _ -> nil
    end
  end

  # --- layer detection ---

  defp detect_layer(path, uses) do
    detect_path_specific_layer(path) ||
      detect_uses_layer(uses) ||
      detect_path_fallback_layer(path)
  end

  defp detect_path_specific_layer(path) do
    cond do
      test_path?(path) -> :test
      operational_path?(path) -> :operational
      true -> nil
    end
  end

  defp detect_uses_layer(uses) do
    detect_app_or_task_layer(uses) ||
      detect_phoenix_role_layer(uses) ||
      detect_ecto_layer(uses)
  end

  defp detect_app_or_task_layer(uses) do
    cond do
      Map.has_key?(uses, Mix.Task) -> :operational
      Map.has_key?(uses, Application) -> :application_root
      true -> nil
    end
  end

  defp detect_phoenix_role_layer(uses) do
    cond do
      uses_role?(uses, [Phoenix.Router], [:router]) -> :router
      uses_role?(uses, [Phoenix.LiveView], [:live_view]) -> :live_view
      uses_role?(uses, [Phoenix.Component], [:live_component, :html, :component]) -> :component
      uses_role?(uses, [Phoenix.Controller], [:controller]) -> :controller
      uses_phoenix_view?(uses) -> :view
      view_only_via_app_helper?(uses) -> :view
      true -> nil
    end
  end

  defp uses_phoenix_view?(uses) do
    case Map.get(uses, Phoenix.View) do
      nil -> false
      _ -> true
    end
  end

  # Atoms passed to `use AppWeb, :atom` that name a view-shape role.
  # Phoenix's framework dispatches to these modules by naming convention
  # (apply(MyView, :template_name, [assigns])) — the AST never sees a
  # call. Modules with these roles are framework-anchored.
  #
  # Project-defined helper variants are common: `:public_view`,
  # `:admin_view`, `:html_view`, etc. The robust signal is any atom
  # that's exactly `:view` OR ends in `_view`.
  defp view_role_atom?(:view), do: true

  defp view_role_atom?(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> String.ends_with?("_view")
  end

  defp view_role_atom?(_), do: false

  # `use AppWeb, :view` (or `:admin_view`, `:public_view`, etc.) where
  # AppWeb is the project's web-helper module. The macro expands to
  # `use Phoenix.View` internally; we can't see the expansion but the
  # second-arg atom is a strong signal.
  defp view_only_via_app_helper?(uses) do
    Enum.any?(uses, fn {_mod, args_list} ->
      Enum.any?(args_list, &view_role_atom?/1)
    end)
  end

  defp detect_ecto_layer(uses) do
    cond do
      Map.has_key?(uses, Ecto.Migration) -> :migration
      Map.has_key?(uses, Ecto.Schema) -> :schema
      true -> nil
    end
  end

  defp detect_path_fallback_layer(path) do
    cond do
      web_path?(path) -> :web
      lib_path?(path) -> :context
      true -> :other
    end
  end

  # `use Mod` matches when Mod ∈ modules.
  # `use AppWeb, :role` matches when :role ∈ roles (`AppWeb` itself is the
  # local web macro module — we don't constrain its name).
  defp uses_role?(uses, modules, roles) do
    Enum.any?(uses, fn {mod, args} ->
      mod in modules or Enum.any?(args, &(&1 in roles))
    end)
  end

  # --- path classification ---

  defp test_path?(file) do
    String.contains?(file, "/test/") or String.starts_with?(file, "test/") or
      String.ends_with?(file, "_test.exs")
  end

  defp operational_path?(file) do
    String.contains?(file, "/mix/tasks/") or String.starts_with?(file, "lib/mix/tasks/") or
      String.contains?(file, "/data_migration/") or
      Path.basename(file) == "release.ex" or
      String.starts_with?(file, "priv/repo/seeds") or
      String.contains?(file, "/priv/repo/seeds")
  end

  defp web_path?(file) do
    String.contains?(file, "_web/") or String.ends_with?(file, "_web.ex")
  end

  defp lib_path?(file) do
    String.starts_with?(file, "lib/") or String.contains?(file, "/lib/")
  end

  # --- uses extraction ---

  defp collect_uses(ast) do
    ast
    |> AST.find_all(fn
      {:use, _, [{:__aliases__, _, parts} | _]} when is_list(parts) ->
        Enum.all?(parts, &is_atom/1)

      _ ->
        false
    end)
    |> Enum.reduce(%{}, fn {:use, _, [{:__aliases__, _, parts} | rest]}, acc ->
      mod = Module.concat(parts)
      args = Enum.map(rest, &AST.unwrap_literal/1)
      Map.update(acc, mod, args, &Enum.concat(args, &1))
    end)
  end

  # --- embed_templates ---

  defp collect_embed_templates(ast) do
    ast
    |> AST.find_all(fn
      {:embed_templates, _, args} when is_list(args) -> true
      _ -> false
    end)
    |> Enum.flat_map(fn {:embed_templates, _, args} -> Enum.flat_map(args, &literal_string/1) end)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the unwrap_literal result shape.
  defp literal_string(arg), do: maybe_string(AST.unwrap_literal(arg))

  defp maybe_string(v) when is_binary(v), do: [v]
  defp maybe_string(_), do: []
end
