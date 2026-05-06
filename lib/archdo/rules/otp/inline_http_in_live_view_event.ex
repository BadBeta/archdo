defmodule Archdo.Rules.OTP.InlineHttpInLiveViewEvent do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

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

  defp find_inline_http(file, ast) do
    case live_view_module?(ast) do
      true -> collect_handle_event_violations(file, ast)
      false -> []
    end
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
end
