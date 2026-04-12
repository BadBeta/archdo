defmodule Archdo.Config do
  @moduledoc false

  @type layer :: :interface | :domain | :infrastructure | :unknown
  @type t :: %__MODULE__{
          layers: %{layer() => Regex.t()},
          allowed_deps: %{layer() => [layer()]},
          contexts: [module()],
          adapters: Regex.t() | nil,
          framework_modules: [Regex.t()],
          overrides: keyword(),
          app_module: String.t() | nil,
          web_module: String.t() | nil
        }

  defstruct layers: %{},
            allowed_deps: %{},
            contexts: [],
            adapters: nil,
            framework_modules: [],
            overrides: [],
            app_module: nil,
            web_module: nil

  @doc """
  Load config from `.archdo.exs` in the project root, falling back to
  convention-based defaults derived from `mix.exs`.
  """
  def load(project_root \\ File.cwd!()) do
    config_path = Path.join(project_root, ".archdo.exs")

    if File.exists?(config_path) do
      {config, _} = Code.eval_file(config_path)
      from_keyword(config, project_root)
    else
      from_conventions(project_root)
    end
  end

  @doc """
  Build config from an explicit keyword list (from .archdo.exs).
  """
  def from_keyword(kw, project_root \\ File.cwd!()) do
    {app, web} = detect_app_modules(project_root)

    %__MODULE__{
      layers: build_layers(Keyword.get(kw, :layers), app, web),
      allowed_deps: build_allowed_deps(Keyword.get(kw, :allowed_deps)),
      contexts: Keyword.get(kw, :contexts, []),
      adapters: Keyword.get(kw, :adapters),
      framework_modules: default_framework_modules(),
      overrides: Keyword.get(kw, :overrides, []),
      app_module: app,
      web_module: web
    }
  end

  @doc """
  Build config purely from Phoenix conventions (zero config).
  """
  def from_conventions(project_root \\ File.cwd!()) do
    {app, web} = detect_app_modules(project_root)

    %__MODULE__{
      layers: default_layers(app, web),
      allowed_deps: default_allowed_deps(),
      contexts: detect_contexts(project_root, app),
      adapters: ~r/\.(Adapters?|Impl|Client)\./,
      framework_modules: default_framework_modules(),
      overrides: [],
      app_module: app,
      web_module: web
    }
  end

  @doc """
  Classify a module into its architectural layer.
  """
  def classify_module(%__MODULE__{} = config, module_name) when is_atom(module_name) do
    classify_module(config, Atom.to_string(module_name) |> String.replace_leading("Elixir.", ""))
  end

  def classify_module(%__MODULE__{layers: layers}, module_name) when is_binary(module_name) do
    Enum.find_value([:interface, :domain, :infrastructure], :unknown, fn layer ->
      case Map.get(layers, layer) do
        nil -> false
        regex -> if Regex.match?(regex, module_name), do: layer, else: false
      end
    end)
  end

  @doc """
  Check if a dependency from source_layer to target_layer is allowed.
  """
  def allowed_dep?(%__MODULE__{allowed_deps: deps}, source_layer, target_layer) do
    source_layer == target_layer or target_layer in Map.get(deps, source_layer, [])
  end

  @doc """
  Check if a module is a framework/web-specific module that domain should not reference.
  """
  def framework_module?(%__MODULE__{framework_modules: patterns}, module_name) when is_binary(module_name) do
    Enum.any?(patterns, &Regex.match?(&1, module_name))
  end

  def framework_module?(config, module_name) when is_atom(module_name) do
    framework_module?(config, Atom.to_string(module_name) |> String.replace_leading("Elixir.", ""))
  end

  @doc """
  Check if a module is an adapter/infrastructure module.
  """
  def adapter_module?(%__MODULE__{adapters: nil}, _module_name), do: false

  def adapter_module?(%__MODULE__{adapters: regex}, module_name) when is_binary(module_name) do
    Regex.match?(regex, module_name)
  end

  def adapter_module?(config, module_name) when is_atom(module_name) do
    adapter_module?(config, Atom.to_string(module_name) |> String.replace_leading("Elixir.", ""))
  end

  @doc """
  Get the context that a module belongs to, if any.
  Returns the context module name or nil.
  """
  def owning_context(%__MODULE__{contexts: contexts}, module_name) when is_binary(module_name) do
    Enum.find(contexts, fn ctx ->
      ctx_str = to_string(ctx) |> String.replace_leading("Elixir.", "")
      module_name == ctx_str or String.starts_with?(module_name, ctx_str <> ".")
    end)
  end

  # --- Private ---

  defp detect_app_modules(project_root) do
    mix_file = Path.join(project_root, "mix.exs")

    if File.exists?(mix_file) do
      content = File.read!(mix_file)

      app_name =
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> Macro.camelize(name)
          _ -> nil
        end

      if app_name do
        {app_name, app_name <> "Web"}
      else
        {nil, nil}
      end
    else
      {nil, nil}
    end
  end

  defp default_layers(nil, _web), do: %{}

  defp default_layers(app, web) do
    %{
      interface: Regex.compile!("^#{Regex.escape(web)}\\."),
      domain: Regex.compile!("^#{Regex.escape(app)}\\.(?!Repo$)"),
      infrastructure: Regex.compile!("^#{Regex.escape(app)}\\.(Repo|Mailer|Infrastructure)")
    }
  end

  defp build_layers(nil, app, web), do: default_layers(app, web)

  defp build_layers(layers_kw, _app, _web) do
    Map.new(layers_kw)
  end

  defp default_allowed_deps do
    %{
      interface: [:domain, :infrastructure],
      domain: [:infrastructure],
      infrastructure: []
    }
  end

  defp build_allowed_deps(nil), do: default_allowed_deps()
  defp build_allowed_deps(deps), do: Map.new(deps)

  defp default_framework_modules do
    [
      ~r/^Phoenix\.Controller/,
      ~r/^Phoenix\.LiveView/,
      ~r/^Phoenix\.LiveComponent/,
      ~r/^Phoenix\.Component/,
      ~r/^Phoenix\.Router/,
      ~r/^Phoenix\.HTML/,
      ~r/^Phoenix\.Channel/,
      ~r/^Phoenix\.Socket/,
      ~r/^Phoenix\.Endpoint/,
      ~r/^Plug\./,
      ~r/^Phoenix\.ConnTest/
    ]
  end

  defp detect_contexts(project_root, nil), do: detect_contexts_from_files(project_root, "")

  defp detect_contexts(project_root, app) do
    detect_contexts_from_files(project_root, app)
  end

  defp detect_contexts_from_files(project_root, app) do
    lib_dir =
      if app != "" do
        app_snake = Macro.underscore(app)
        Path.join([project_root, "lib", app_snake])
      else
        Path.join(project_root, "lib")
      end

    if File.dir?(lib_dir) do
      lib_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.map(fn file ->
        file
        |> String.trim_trailing(".ex")
        |> Macro.camelize()
        |> then(fn name ->
          # Module.concat accepts strings — no atom creation needed
          if app != "", do: Module.concat([app, name]), else: Module.concat([name])
        end)
      end)
    else
      []
    end
  end
end
