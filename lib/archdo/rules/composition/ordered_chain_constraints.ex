defmodule Archdo.Rules.Composition.OrderedChainConstraints do
  @moduledoc false
  @behaviour Archdo.Rule

  # 10.6. An ordered list of middleware (Phoenix Plug pipelines, and
  # by extension any chain shaped the same way) imposes structural
  # constraints: certain entries must precede others, certain
  # categories must be present in certain pipeline shapes, and an
  # entry must not appear twice in one chain. The current
  # implementation handles Plug pipelines (`pipeline :name do ... end`
  # in routers); the category catalogs are kept module-local so a
  # future configuration mechanism can swap them.

  alias Archdo.{AST, Diagnostic, Fix}

  @auth_plugs [
    :authenticate,
    :authenticate_user,
    :require_authenticated,
    :require_authenticated_user,
    :fetch_current_user,
    :ensure_authenticated
  ]

  @authz_plugs [
    :authorize,
    :require_admin,
    :require_role,
    :check_permission,
    :ensure_authorized
  ]

  @csrf_plugs [:protect_from_forgery]
  @session_plugs [:fetch_session]
  @parsers_modules [[:Plug, :Parsers]]
  @browser_signal_plugs [:put_root_layout, :put_secure_browser_headers, :fetch_live_flash]

  @impl true
  def id, do: "10.6"

  @impl true
  def description,
    do: "Ordered middleware chain (Plug pipeline) violates ordering, presence, or uniqueness rules"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_pipelines(ast) |> Enum.flat_map(&check_pipeline(file, &1))
    end
  end

  defp find_pipelines(ast) do
    {_, pipelines} =
      Macro.prewalk(ast, [], fn
        {:pipeline, meta, [name, [do: body]]} = node, acc when is_atom(name) ->
          {node, [{name, meta, plug_entries(body)} | acc]}

        node, acc ->
          {node, acc}
      end)

    pipelines
  end

  defp plug_entries({:__block__, _, statements}), do: Enum.flat_map(statements, &plug_entry/1)
  defp plug_entries(single), do: plug_entry(single)

  defp plug_entry({:plug, meta, args}) do
    case args do
      [first | _] -> [%{key: plug_key(first), display: plug_display(first), meta: meta}]
      _ -> []
    end
  end

  defp plug_entry(_), do: []

  defp plug_key(name) when is_atom(name), do: {:atom, name}
  defp plug_key({:__aliases__, _, parts}), do: {:module, parts}
  defp plug_key(other), do: {:other, other}

  defp plug_display(name) when is_atom(name), do: ":#{name}"
  defp plug_display({:__aliases__, _, parts}), do: Enum.join(parts, ".")
  defp plug_display(_), do: "(complex)"

  defp check_pipeline(file, {name, meta, entries}) do
    line = AST.line(meta)

    auth_keys = Enum.map(@auth_plugs, &{:atom, &1})
    authz_keys = Enum.map(@authz_plugs, &{:atom, &1})
    parsers_keys = Enum.map(@parsers_modules, &{:module, &1})
    session_keys = Enum.map(@session_plugs, &{:atom, &1})

    [
      duplicates(file, name, line, entries),
      ordering(file, name, line, entries, auth_keys, authz_keys, "auth", "authz"),
      ordering(file, name, line, entries, parsers_keys, session_keys, "Plug.Parsers", "session"),
      missing_csrf(file, name, line, entries)
    ]
    |> List.flatten()
  end

  defp duplicates(file, pipeline, line, entries) do
    entries
    |> Enum.group_by(& &1.key)
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.map(fn {_key, group} ->
      [first | _] = group
      build_duplicate(file, pipeline, line, first.display)
    end)
  end

  defp ordering(file, pipeline, line, entries, before_set, after_set, before_label, after_label) do
    {_, before_index, after_index} =
      Enum.reduce(entries, {0, nil, nil}, fn entry, {idx, before_idx, after_idx} ->
        new_before = before_idx || maybe_index(entry.key, before_set, idx)
        new_after = after_idx || maybe_index(entry.key, after_set, idx)
        {idx + 1, new_before, new_after}
      end)

    case {before_index, after_index} do
      {b, a} when is_integer(b) and is_integer(a) and a < b ->
        [build_ordering(file, pipeline, line, before_label, after_label)]

      _ ->
        []
    end
  end

  defp maybe_index(key, set, idx) do
    case key_in_set?(key, set) do
      true -> idx
      false -> nil
    end
  end

  defp key_in_set?(key, set), do: key in set

  defp missing_csrf(file, pipeline, line, entries) do
    case browser_pipeline?(pipeline, entries) and not has_csrf?(entries) do
      true -> [build_csrf(file, pipeline, line)]
      false -> []
    end
  end

  defp browser_pipeline?(:browser, _entries), do: true

  defp browser_pipeline?(_, entries) do
    Enum.any?(entries, fn entry ->
      browser_signal?(entry.key)
    end)
  end

  defp browser_signal?({:atom, name}) do
    name in @browser_signal_plugs
  end

  defp browser_signal?(_), do: false

  defp has_csrf?(entries) do
    Enum.any?(entries, fn entry ->
      case entry.key do
        {:atom, name} -> name in @csrf_plugs
        _ -> false
      end
    end)
  end

  defp build_duplicate(file, pipeline, line, display) do
    Diagnostic.warning("10.6",
      title: "Duplicate plug in pipeline",
      message: "Pipeline :#{pipeline} has a duplicate plug: #{display}",
      why:
        "A plug declared twice in the same pipeline is almost always a refactor leftover. " <>
          "It runs twice — once with the original config and once with whatever the second " <>
          "instance specifies — and any state the plug sets is overwritten.",
      alternatives: [
        Fix.new(
          summary: "Remove the duplicate",
          detail: "Keep the instance with the correct configuration; delete the other.",
          applies_when: "Always."
        )
      ],
      references: [],
      context: %{pipeline: ":#{pipeline}", plug: display},
      file: file,
      line: line
    )
  end

  defp build_ordering(file, pipeline, line, before_label, after_label) do
    Diagnostic.warning("10.6",
      title: "Ordered chain violation: #{after_label} runs before #{before_label}",
      message:
        "Pipeline :#{pipeline} has #{after_label} entries before #{before_label} entries — " <>
          "the chain runs out of order",
      why:
        "Middleware ordering encodes a real dependency: #{before_label} must run before " <>
          "#{after_label} for the chain to be sound. Reordering at runtime is not safe; " <>
          "the configuration has to be corrected here.",
      alternatives: [
        Fix.new(
          summary: "Reorder the pipeline so #{before_label} comes first",
          detail:
            "Move every #{before_label} plug ahead of every #{after_label} plug. The chain " <>
              "executes in declaration order.",
          applies_when: "Always."
        )
      ],
      references: [],
      context: %{pipeline: ":#{pipeline}"},
      file: file,
      line: line
    )
  end

  defp build_csrf(file, pipeline, line) do
    Diagnostic.warning("10.6",
      title: "Browser pipeline missing CSRF protection",
      message:
        "Pipeline :#{pipeline} looks like a browser pipeline but does not include " <>
          "`:protect_from_forgery`",
      why:
        "Browser pipelines that handle session-bearing form submissions need CSRF protection. " <>
          "Without `:protect_from_forgery`, a session-authenticated user can be tricked into " <>
          "submitting a form that performs an action on their behalf from a third-party site.",
      alternatives: [
        Fix.new(
          summary: "Add `plug :protect_from_forgery`",
          detail:
            "Place `plug :protect_from_forgery` after `:fetch_session` so the CSRF check has " <>
              "the session available.",
          applies_when: "The pipeline serves browser routes that accept POST/PUT/DELETE."
        )
      ],
      references: [],
      context: %{pipeline: ":#{pipeline}"},
      file: file,
      line: line
    )
  end
end
