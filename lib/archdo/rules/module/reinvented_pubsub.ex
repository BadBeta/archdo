defmodule Archdo.Rules.Module.ReinventedPubSub do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.15"

  @impl true
  def description, do: "Custom pubsub/observer reinvention — use Registry or Phoenix.PubSub"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      check_reinvented_pubsub(file, ast)
    end
  end

  defp check_reinvented_pubsub(file, ast) do
    fns = AST.extract_functions(ast, :public)
    names = Enum.map(fns, fn {name, _arity, _, _, _} -> name end)

    has_subscribe = has_pubsub_function?(names, ["subscribe", "listen", "watch"])
    has_broadcast = has_pubsub_function?(names, ["broadcast", "notify", "publish", "emit"])
    has_unsubscribe = has_pubsub_function?(names, ["unsubscribe", "unlisten", "unwatch"])

    uses_registry? = uses_module?(ast, [:Registry])
    uses_phoenix_pubsub? = uses_module?(ast, [:Phoenix, :PubSub])
    uses_pg? = uses_module?(ast, [:pg]) or uses_erlang_pg?(ast)
    uses_telemetry? = uses_module?(ast, [:Telemetry, :Metrics]) or uses_erlang_telemetry?(ast)

    # If the pubsub functions just delegate to another module's pubsub functions,
    # that's a wrapper, not a reinvention
    delegates_to_another_module? = delegates_pubsub?(fns)

    # Real reinvention signals: sends messages to tracked pids, holds a
    # subscriber list in GenServer state, or uses ets/Map for subscribers.
    maintains_subscriber_list? = maintains_subscriber_list?(ast)

    reinventing? =
      has_subscribe and has_broadcast and
        not delegates_to_another_module? and
        maintains_subscriber_list? and
        not (uses_registry? or uses_phoenix_pubsub? or uses_pg? or uses_telemetry?)

    if reinventing? do
      module_name = AST.extract_module_name(ast)
      fn_list = [has_subscribe && "subscribe", has_unsubscribe && "unsubscribe", has_broadcast && "broadcast"]
               |> Enum.reject(&(&1 == false))
               |> Enum.join("/")

      [
        Diagnostic.warning("4.15",
          title: "Hand-rolled pubsub",
          message: "#{module_name} implements #{fn_list} on top of its own subscriber list",
          why:
            "Phoenix.PubSub, Registry (with :duplicate keys), and `:pg` already solve the subscriber-list " <>
              "problem with concurrent dispatch, automatic cleanup when subscribers die, and (in PubSub's case) " <>
              "cluster-wide fanout. A custom GenServer-as-pubsub typically loses cleanup on process death, " <>
              "becomes a single bottleneck for all dispatch, and accumulates dead pids over time.",
          alternatives: [
            Fix.new(
              summary: "Use Phoenix.PubSub for fan-out",
              detail:
                "Add `{Phoenix.PubSub, name: MyApp.PubSub}` to your supervision tree. Replace `subscribe/1` " <>
                  "with `Phoenix.PubSub.subscribe(MyApp.PubSub, topic)` and `broadcast/1` with " <>
                  "`Phoenix.PubSub.broadcast(MyApp.PubSub, topic, message)`. Subscribers automatically clean up " <>
                  "when they die.",
              applies_when: "The pattern is publish/subscribe to topics."
            ),
            Fix.new(
              summary: "Use Registry with `:duplicate` keys",
              detail:
                "If you don't need PubSub's cluster support, a Registry with `keys: :duplicate` is lighter " <>
                  "weight. Subscribers register themselves; the publisher iterates Registry.dispatch. Cleanup " <>
                  "is automatic.",
              applies_when: "Single-node fan-out without PubSub overhead."
            ),
            Fix.new(
              summary: "Use `:telemetry` for observability events",
              detail:
                "If the events are about reporting state changes (metrics, logging, observability), use " <>
                  "`:telemetry.execute/3` and let consumers attach handlers. No subscriber list to maintain.",
              applies_when: "The events are observability-focused, not business commands."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#4.15"],
          context: %{module: module_name},
          file: file,
          line: 1
        )
      ]
    else
      []
    end
  end

  defp has_pubsub_function?(names, patterns) do
    Enum.any?(names, fn
      name when is_atom(name) ->
        name_str = Atom.to_string(name)
        Enum.any?(patterns, &String.contains?(name_str, &1))

      _ ->
        false
    end)
  end

  defp uses_module?(ast, path) do
    AST.contains?(ast, fn
      {:alias, _, [{:__aliases__, _, parts} | _]} -> parts == path
      {:import, _, [{:__aliases__, _, parts} | _]} -> parts == path
      {{:., _, [{:__aliases__, _, parts}, _]}, _, _} -> parts == path
      _ -> false
    end)
  end

  defp uses_erlang_pg?(ast) do
    AST.contains?(ast, fn
      {{:., _, [:pg, _]}, _, _} -> true
      _ -> false
    end)
  end

  defp uses_erlang_telemetry?(ast) do
    AST.contains?(ast, fn
      {{:., _, [:telemetry, _]}, _, _} -> true
      _ -> false
    end)
  end

  # A function whose body is mostly a call to another module's function with
  # the same name is delegation, not reinvention.
  defp delegates_pubsub?(fns) do
    pubsub_fns =
      Enum.filter(fns, fn
        {name, _arity, _, _, _} when is_atom(name) ->
          name_str = Atom.to_string(name)

          Enum.any?(
            ["subscribe", "broadcast", "publish", "notify", "emit"],
            &String.contains?(name_str, &1)
          )

        _ ->
          false
      end)

    Enum.any?(pubsub_fns, fn {_name, _arity, _, _, body} ->
      body != nil and
        AST.contains?(body, fn
          {{:., _, [{:__aliases__, _, _}, _]}, _, _} -> true
          _ -> false
        end)
    end)
  end

  # Real reinvention: the module maintains a list of subscribers in state
  # (GenServer with a Map, ETS table holding pids, etc.)
  defp maintains_subscriber_list?(ast) do
    # Heuristic: the module is a GenServer AND references :ets.new or holds
    # a Map/MapSet of pids in its state
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:GenServer]} | _]} -> true
      _ -> false
    end) and
      AST.contains?(ast, fn
        {{:., _, [:ets, :new]}, _, _} -> true
        {:subscribers, _, _} -> true
        {:listeners, _, _} -> true
        {:observers, _, _} -> true
        _ -> false
      end)
  end
end
