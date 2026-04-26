defmodule Archdo.Metrics do
  @moduledoc false

  # Robert C. Martin's package metrics, adapted to Elixir modules.
  #
  # * Ca (Afferent Coupling)  — number of distinct modules that depend ON this module
  # * Ce (Efferent Coupling)  — number of distinct modules that this module depends ON
  # * I  (Instability)        — Ce / (Ca + Ce), range [0,1]
  #                             0 = maximally stable (everyone depends on you, you depend on no one)
  #                             1 = maximally unstable (you depend on many, no one depends on you)
  # * A  (Abstractness)       — N_abstract / N_total
  #                             A module is "abstract" if it defines @callback (behaviour)
  #                             or is a protocol. Range [0,1].
  # * D  (Distance from main sequence) — |A + I - 1|
  #                                       0 = on the main sequence (good)
  #                                       → 1 = zone of pain (concrete + stable) OR
  #                                             zone of uselessness (abstract + unstable)
  #
  # The "main sequence" is the line from (A=0, I=1) — concrete and unstable, fine —
  # to (A=1, I=0) — abstract and stable, fine. Everything far from this line is problematic.

  alias Archdo.{AST, Graph}

  @type module_metrics :: %{
          module: String.t(),
          ca: non_neg_integer(),
          ce: non_neg_integer(),
          instability: float(),
          abstractness: float(),
          distance: float()
        }

  @doc """
  Compute Martin metrics for all modules in the project.

  Takes the module dependency graph and the parsed file ASTs
  (the ASTs are needed to detect abstractness — looking for @callback
  attributes and defprotocol blocks).
  """
  @spec compute(Graph.t(), [{String.t(), Macro.t()}]) :: [module_metrics()]
  def compute(%Graph{} = graph, file_asts) do
    abstract_modules = identify_abstract_modules(file_asts)

    modules =
      graph.modules
      |> MapSet.to_list()
      |> Enum.reject(&stdlib?/1)

    Enum.map(modules, fn mod ->
      ca = afferent_coupling(graph, mod)
      ce = efferent_coupling(graph, mod)
      instability = compute_instability(ca, ce)

      abstractness =
        case MapSet.member?(abstract_modules, mod) do
          true -> 1.0
          false -> 0.0
        end

      distance = abs(abstractness + instability - 1.0)

      %{
        module: mod,
        ca: ca,
        ce: ce,
        instability: instability,
        abstractness: abstractness,
        distance: distance
      }
    end)
  end

  @doc """
  Efferent coupling: count of distinct modules this module depends on
  (excluding stdlib and self).
  """
  @spec efferent_coupling(Archdo.Graph.t(), String.t()) :: non_neg_integer()
  def efferent_coupling(%Graph{} = graph, module) do
    graph
    |> Graph.dependencies(module)
    |> Enum.map(& &1.target)
    |> Enum.uniq()
    |> Enum.reject(fn target -> target == module or stdlib?(target) end)
    |> length()
  end

  @doc """
  Afferent coupling: count of distinct modules that depend on this module
  (excluding stdlib and self).
  """
  @spec afferent_coupling(Archdo.Graph.t(), String.t()) :: non_neg_integer()
  def afferent_coupling(%Graph{edges: edges}, module) do
    edges
    |> Enum.filter(fn edge -> edge.target == module end)
    |> Enum.map(& &1.source)
    |> Enum.uniq()
    |> Enum.reject(fn source -> source == module or stdlib?(source) end)
    |> length()
  end

  defp compute_instability(0, 0), do: 0.0
  defp compute_instability(ca, ce), do: ce / (ca + ce)

  # A module is "abstract" in Martin's sense if it exposes extension points:
  # - Defines @callback attributes (behaviour)
  # - Is a protocol (defprotocol)
  # - Is heavily built on @impl true from an external behaviour (less clear, skipped)
  defp identify_abstract_modules(file_asts) do
    file_asts
    |> Enum.flat_map(fn {_file, ast} ->
      if abstract_module?(ast) do
        [AST.extract_module_name(ast)]
      else
        []
      end
    end)
    |> MapSet.new()
  end

  defp abstract_module?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:callback, _, _}]} -> true
      {:defprotocol, _, _} -> true
      _ -> false
    end)
  end

  # Heuristic: anything in a top-level stdlib-ish namespace is excluded
  # from metrics so we only measure the project's own modules.
  defp stdlib?(name) when is_binary(name) do
    top =
      name
      |> String.split(".")
      |> hd()

    top in ~w(
      Enum List Map MapSet Keyword Process Kernel IO File Path String Integer Float
      Atom Tuple Range Stream Function Module Code Macro Application System
      Logger GenServer Agent Task Supervisor DynamicSupervisor Registry
      Ecto Phoenix Plug Regex Date Time DateTime NaiveDateTime Calendar
      Base64 Bitwise Exception Access URI Version Jason Poison Mox
      Commanded Ash AshPostgres AshPhoenix Oban Broadway GenStage
      Finch HTTPoison Tesla Req Swoosh Bamboo
    )
  end

  defp stdlib?(_), do: false
end
