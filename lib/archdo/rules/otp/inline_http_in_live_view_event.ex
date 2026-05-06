defmodule Archdo.Rules.OTP.InlineHttpInLiveViewEvent do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix, FunctionGraph}

  # Direct HTTP-call seeds — same set used by per-file detection (below) and by
  # the project-level taint-set fixed-point (analyze_project/1).
  @http_seeds [
    {"Tesla", :get},
    {"Tesla", :get!},
    {"Tesla", :post},
    {"Tesla", :post!},
    {"Tesla", :put},
    {"Tesla", :put!},
    {"Tesla", :patch},
    {"Tesla", :patch!},
    {"Tesla", :delete},
    {"Tesla", :delete!},
    {"Tesla", :request},
    {"Tesla", :request!},
    {"Tesla", :head},
    {"Tesla", :head!},
    {"Req", :get},
    {"Req", :get!},
    {"Req", :post},
    {"Req", :post!},
    {"Req", :put},
    {"Req", :put!},
    {"Req", :patch},
    {"Req", :patch!},
    {"Req", :delete},
    {"Req", :delete!},
    {"Req", :request},
    {"Req", :request!},
    {"HTTPoison", :get},
    {"HTTPoison", :get!},
    {"HTTPoison", :post},
    {"HTTPoison", :post!},
    {"HTTPoison", :put},
    {"HTTPoison", :put!},
    {"HTTPoison", :patch},
    {"HTTPoison", :patch!},
    {"HTTPoison", :delete},
    {"HTTPoison", :delete!},
    {"HTTPoison", :request},
    {"HTTPoison", :request!},
    {"HTTPoison", :head},
    {"HTTPoison", :head!},
    {"Finch", :request},
    {"Finch", :request!},
    {":httpc", :request}
  ]

  @max_taint_depth 5

  @impl true
  def id, do: "5.76"

  @impl true
  def description,
    do: "Blocking HTTP call in LiveView `handle_event/3` — freezes the LV process"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_inline_http(file, ast)
    end
  end

  @doc """
  Project-level analysis: builds a transitive HTTP-taint set via fixed-point
  iteration over `Archdo.FunctionGraph.calls`, then walks every LiveView
  module's `handle_event/3` body for INDIRECT calls into the taint set.

  Direct HTTP calls (caller body literally invokes `Tesla.delete`) are caught
  by `analyze/3` per-file. This function fills the gap: callers that wrap
  `Tesla.*` inside helper modules (e.g. `Vercel.Client.delete_log_drain`).
  """
  @spec analyze_project([{String.t(), Macro.t()}]) :: [Diagnostic.t()]
  def analyze_project(file_asts) do
    fn_graph = FunctionGraph.build(file_asts)
    taint = build_taint_set(fn_graph)

    file_asts
    |> Enum.reject(fn {file, _ast} -> AST.test_file?(file) end)
    |> Enum.flat_map(fn {file, ast} -> find_indirect_http(file, ast, taint) end)
  end

  defp find_inline_http(file, ast) do
    case live_view_module?(ast) do
      true -> collect_handle_event_violations(file, ast)
      false -> []
    end
  end

  # --- Project-level (graph-based) indirect HTTP detection ---

  defp find_indirect_http(file, ast, taint) do
    case live_view_module?(ast) do
      true -> collect_indirect_handle_event_violations(file, ast, taint)
      false -> []
    end
  end

  defp collect_indirect_handle_event_violations(file, ast, taint) do
    ast
    |> AST.find_all(&handle_event_def?/1)
    |> Enum.flat_map(fn node -> indirect_http_in(node, file, taint) end)
  end

  defp indirect_http_in(def_node, file, taint) do
    def_node
    |> walk_skipping_async_for_indirect([], taint)
    |> Enum.map(fn {node, mfa} ->
      build_indirect_diagnostic(file, AST.line(call_meta(node)), mfa)
    end)
  end

  # Same shape as walk_skipping_async/2 but collects {node, mfa} for any
  # remote function call site whose target is in the taint set.
  defp walk_skipping_async_for_indirect(node, acc, taint) do
    case async_wrapper?(node) do
      true ->
        acc

      false ->
        acc = maybe_collect_indirect(node, acc, taint)

        Enum.reduce(children(node), acc, fn child, a ->
          walk_skipping_async_for_indirect(child, a, taint)
        end)
    end
  end

  defp maybe_collect_indirect(node, acc, taint) do
    case indirect_http_target(node, taint) do
      nil -> acc
      mfa -> [{node, mfa} | acc]
    end
  end

  # Returns {module_str, fn_name, arity} if the AST node is a remote call
  # whose target is in the taint set; nil otherwise. Skips direct HTTP
  # calls (those are caught by analyze/3 already). Handles both direct
  # `Mod.fun(args)` and pipe form `subj |> Mod.fun(args)` (effective arity
  # = args + 1 — same convention FunctionGraph uses).
  defp indirect_http_target(node, taint) do
    case remote_call_mfa(node) do
      nil ->
        nil

      {mod, fun, _arity} = mfa ->
        case http_seed?(mod, fun) do
          true -> nil
          false -> taint_lookup(mfa, taint)
        end
    end
  end

  # Pipe form: `lhs |> Mod.fun(args)` — effective arity is args + 1.
  defp remote_call_mfa({:|>, _, [_lhs, {{:., _, [{:__aliases__, _, segments}, fun]}, _, args}]})
       when is_list(args) and is_atom(fun) and is_list(segments) do
    {Enum.map_join(segments, ".", &Atom.to_string/1), fun, length(args) + 1}
  end

  defp remote_call_mfa({:|>, _, [_lhs, {{:., _, [mod_atom, fun]}, _, args}]})
       when is_atom(mod_atom) and is_atom(fun) and is_list(args) do
    {":" <> Atom.to_string(mod_atom), fun, length(args) + 1}
  end

  defp remote_call_mfa({{:., _, [{:__aliases__, _, segments}, fun]}, _, args})
       when is_list(args) and is_atom(fun) and is_list(segments) do
    {Enum.map_join(segments, ".", &Atom.to_string/1), fun, length(args)}
  end

  defp remote_call_mfa({{:., _, [mod_atom, fun]}, _, args})
       when is_atom(mod_atom) and is_atom(fun) and is_list(args) do
    {":" <> Atom.to_string(mod_atom), fun, length(args)}
  end

  defp remote_call_mfa(_), do: nil

  defp http_seed?(mod, fun), do: {mod, fun} in @http_seeds

  defp taint_lookup({mod, fun, arity}, taint) do
    case Map.get(taint, {mod, fun, arity}) do
      nil -> nil
      _depth -> {mod, fun, arity}
    end
  end

  # --- Taint-set fixed-point ---

  # Returns %{ {module, fn, arity} => depth } for every fn whose body calls
  # an HTTP-seed (depth 1) or a tainted fn (depth N+1). Stops at @max_taint_depth.
  defp build_taint_set(%FunctionGraph{calls: calls}) do
    seeds = seed_taint(calls)
    fixed_point(seeds, calls)
  end

  defp seed_taint(calls) do
    Enum.reduce(calls, %{}, fn call, acc ->
      case http_seed?(call.target_module, call.target_fn) do
        true -> add_taint(acc, caller_key(call), 1)
        false -> acc
      end
    end)
  end

  defp fixed_point(taint, calls) do
    new_taint =
      Enum.reduce(calls, taint, fn call, acc ->
        target_key = {call.target_module, call.target_fn, call.target_arity}

        case Map.get(taint, target_key) do
          nil -> acc
          depth when depth >= @max_taint_depth -> acc
          depth -> add_taint(acc, caller_key(call), depth + 1)
        end
      end)

    case map_size(new_taint) == map_size(taint) do
      true -> new_taint
      false -> fixed_point(new_taint, calls)
    end
  end

  defp caller_key(call), do: {call.caller_module, call.caller_fn, call.caller_arity}

  # Add taint entries for the canonical key AND every alias-suffix form, since
  # FunctionGraph stores `target_module` as-typed (alias not resolved). A call
  # to `Vercel.Client.foo` from a file with `alias Logflare.Vercel.Client`
  # records `target_module = "Vercel.Client"`, while the def lives at canonical
  # `"Logflare.Vercel.Client"`. Indexing both lets exact lookup succeed for
  # both the canonical and any alias-suffix the caller wrote.
  defp add_taint(taint, {full_mod, fun, arity}, depth) do
    full_mod
    |> module_suffixes()
    |> Enum.reduce(taint, fn mod, acc ->
      Map.update(acc, {mod, fun, arity}, depth, &min(&1, depth))
    end)
  end

  defp module_suffixes(full_mod) do
    parts = String.split(full_mod, ".")
    for n <- 1..length(parts), do: parts |> Enum.take(-n) |> Enum.join(".")
  end

  # `use Phoenix.LiveView` OR `use _, :live_view` (Phoenix convention).
  defp live_view_module?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Phoenix, :LiveView]} | _]} ->
        true

      {:use, _, [{:__aliases__, _, _}, second]} ->
        AST.unwrap_literal(second) == :live_view

      _ ->
        false
    end)
  end

  defp collect_handle_event_violations(file, ast) do
    ast
    |> AST.find_all(&handle_event_def?/1)
    |> Enum.flat_map(fn node -> blocking_http_in(node, file) end)
  end

  # Match `def handle_event(event, params, socket) do ... end` (with or without `when`).
  defp handle_event_def?({:def, _, [{:handle_event, _, args} | _]})
       when is_list(args) and length(args) == 3,
       do: true

  defp handle_event_def?({:def, _, [{:when, _, [{:handle_event, _, args} | _]} | _]})
       when is_list(args) and length(args) == 3,
       do: true

  defp handle_event_def?(_), do: false

  defp blocking_http_in(def_node, file) do
    def_node
    |> walk_skipping_async([])
    |> Enum.map(fn node -> build_diagnostic(file, AST.line(call_meta(node)), describe(node)) end)
  end

  # Walk `node`, collect blocking-HTTP calls, but DO NOT descend into
  # children of `start_async` / `assign_async` / `Task.async` /
  # `Task.async_stream` — anything inside those is by-design async.
  defp walk_skipping_async(node, acc) do
    case async_wrapper?(node) do
      true ->
        acc

      false ->
        acc = maybe_collect(node, acc)
        Enum.reduce(children(node), acc, &walk_skipping_async/2)
    end
  end

  defp maybe_collect(node, acc) do
    case blocking_http_call?(node) do
      true -> [node | acc]
      false -> acc
    end
  end

  # async wrappers — calls whose argument lambdas should be skipped.
  defp async_wrapper?({:start_async, _, _}), do: true
  defp async_wrapper?({:assign_async, _, _}), do: true

  defp async_wrapper?({{:., _, [{:__aliases__, _, [:Task]}, op]}, _, _})
       when op in [:async, :async_stream, :async_nolink, :start, :start_link],
       do: true

  defp async_wrapper?(_), do: false

  defp children({_, _, args}) when is_list(args), do: args
  defp children(list) when is_list(list), do: list
  defp children({a, b}), do: [a, b]
  defp children(_), do: []

  defp call_meta({_, meta, _}), do: meta

  # Blocking HTTP clients
  defp blocking_http_call?({{:., _, [{:__aliases__, _, [:Req]}, op]}, _, _})
       when op in [
              :get,
              :get!,
              :post,
              :post!,
              :put,
              :put!,
              :patch,
              :patch!,
              :delete,
              :delete!,
              :request,
              :request!
            ],
       do: true

  defp blocking_http_call?({{:., _, [{:__aliases__, _, [:HTTPoison]}, op]}, _, _})
       when op in [
              :get,
              :get!,
              :post,
              :post!,
              :put,
              :put!,
              :patch,
              :patch!,
              :delete,
              :delete!,
              :request,
              :request!,
              :head,
              :head!
            ],
       do: true

  defp blocking_http_call?({{:., _, [{:__aliases__, _, [:Tesla]}, op]}, _, _})
       when op in [
              :get,
              :get!,
              :post,
              :post!,
              :put,
              :put!,
              :patch,
              :patch!,
              :delete,
              :delete!,
              :request,
              :request!,
              :head,
              :head!
            ],
       do: true

  defp blocking_http_call?({{:., _, [{:__aliases__, _, [:Finch]}, op]}, _, _})
       when op in [:request, :request!],
       do: true

  defp blocking_http_call?({{:., _, [:httpc, :request]}, _, _}), do: true

  defp blocking_http_call?(_), do: false

  defp describe({{:., _, [{:__aliases__, _, [mod]}, _]}, _, _}), do: Atom.to_string(mod)
  defp describe({{:., _, [:httpc, _]}, _, _}), do: ":httpc"
  defp describe(_), do: "HTTP client"

  defp build_diagnostic(file, line, lib) do
    Diagnostic.warning("5.76",
      title: "Blocking HTTP in LiveView `handle_event/3`",
      message:
        "`handle_event/3` calls #{lib} synchronously — the LiveView process " <>
          "is frozen for the duration of the request, blocking all other " <>
          "events for this user.",
      why:
        "A LiveView is a single GenServer per user session. While " <>
          "`handle_event/3` is running, no other events for this user are " <>
          "processed — clicks queue up, the UI feels unresponsive, and a " <>
          "single slow API call can hang the entire session. Wrap the call " <>
          "in `start_async/3`: the LV stays responsive, and the result is " <>
          "delivered via `handle_async/3`. This is the continuation-passing " <>
          "shape — the rest of the handler becomes the continuation, and " <>
          "the LV remains free to process other events meanwhile.",
      alternatives: [
        Fix.new(
          summary: "Wrap with `start_async/3` + `handle_async/3`",
          detail:
            "Move the blocking call into a `start_async` lambda. Add a " <>
              "`handle_async/3` callback to receive the result.",
          example: """
          ```elixir
          # before — freezes the LV during the HTTP call
          def handle_event("fetch", _, socket) do
            {:ok, response} = Req.get("https://api/users")
            {:noreply, assign(socket, users: response.body)}
          end

          # after — LV stays responsive
          def handle_event("fetch", _, socket) do
            {:noreply, start_async(socket, :fetch_users, fn ->
              Req.get!("https://api/users").body
            end)}
          end

          def handle_async(:fetch_users, {:ok, users}, socket) do
            {:noreply, assign(socket, users: users)}
          end
          ```
          """,
          applies_when: "The result is rendered to the user — async fits naturally."
        ),
        Fix.new(
          summary: "Use `assign_async/3` for mount-time loads",
          detail:
            "If the data should appear when the LV first mounts, use " <>
              "`assign_async/3` instead — it gives loading/error states " <>
              "with `<.async_result>` for free.",
          applies_when: "The data is part of initial page render."
        )
      ],
      file: file,
      line: line
    )
  end

  defp build_indirect_diagnostic(file, line, {mod, fun, arity}) do
    Diagnostic.warning("5.76",
      title: "Indirect blocking HTTP in LiveView `handle_event/3`",
      message:
        "`handle_event/3` calls `#{mod}.#{fun}/#{arity}`, which transitively " <>
          "wraps a synchronous HTTP call (Tesla / Req / HTTPoison / Finch / " <>
          ":httpc). The LiveView process is frozen for the duration of the " <>
          "request, blocking all other events for this user.",
      why:
        "A LiveView is a single GenServer per user session. Hidden HTTP calls " <>
          "behind a wrapper module are just as blocking as direct ones — the " <>
          "wrapper merely obscures where the freeze happens. Wrap the call " <>
          "site (or the whole helper) in `start_async/3` so the LV stays " <>
          "responsive and the result arrives via `handle_async/3`.",
      alternatives: [
        Fix.new(
          summary: "Wrap the wrapper call in `start_async/3` + `handle_async/3`",
          detail:
            "Move `#{mod}.#{fun}/#{arity}` into a `start_async` lambda. Add a " <>
              "`handle_async/3` callback to receive the result.",
          applies_when: "The result is rendered to the user — async fits naturally."
        )
      ],
      file: file,
      line: line
    )
  end
end
