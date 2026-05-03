defmodule Archdo.Rules.Module.StacktraceInResponse do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.52"

  @impl true
  def description,
    do: "__STACKTRACE__ leaked across response boundary — exposes internal topology"

  @impl true
  def cleanup_pass, do: 5

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> maybe_analyze(file, ast)
    end
  end

  # §§ elixir-implementing: §5.2 — multi-clause head, no if/else.
  defp maybe_analyze(file, ast) do
    case boundary_file?(file) do
      true -> find_stacktrace_leaks(ast, file)
      false -> []
    end
  end

  # Boundary surface: anywhere a function's return value can become an outbound
  # response. Phoenix controller/channel/live, JSON view modules, Absinthe
  # resolvers. The rule fires only inside these — domain modules can carry the
  # stacktrace freely (the boundary is responsible for sanitizing).
  @boundary_markers [
    "_controller.ex",
    "/controllers/",
    "_channel.ex",
    "/channels/",
    "_live.ex",
    "/live/",
    "_view.ex",
    "/views/",
    "_json.ex",
    "/json/",
    "_resolver.ex",
    "/resolvers/"
  ]

  defp boundary_file?(file) do
    Enum.any?(@boundary_markers, &String.contains?(file, &1))
  end

  defp find_stacktrace_leaks(ast, file) do
    ast
    |> walk(false)
    |> Enum.reverse()
    |> Enum.map(&build_diagnostic(file, &1))
  end

  # walk(node, in_safe_wrapper?) -> list of meta for unsafe __STACKTRACE__ uses.
  # `in_safe_wrapper?` flips to true when entering a Logger.X / :telemetry.execute
  # call; children of that call do not produce diagnostics.
  defp walk(node, in_safe?, acc \\ [])

  # __STACKTRACE__ — the trigger
  defp walk({:__STACKTRACE__, meta, _}, false, acc), do: [meta | acc]
  defp walk({:__STACKTRACE__, _meta, _}, true, acc), do: acc

  # Logger.<level>(...) — Logger module call
  defp walk({{:., _, [{:__aliases__, _, [:Logger]}, _level]}, _meta, args}, _in_safe?, acc) do
    walk_children(args, true, acc)
  end

  # :telemetry.execute(...) — the canonical safe drain for stacktraces
  defp walk({{:., _, [:telemetry, :execute]}, _meta, args}, _in_safe?, acc) do
    walk_children(args, true, acc)
  end

  # `require Logger; Logger.X(...)` after import — bare call form
  defp walk({fun, _meta, args}, _in_safe?, acc)
       when fun in [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency] and
              is_list(args) do
    walk_children(args, true, acc)
  end

  # 3-tuple AST node — recurse into args
  defp walk({form, _meta, args}, in_safe?, acc) when is_list(args) do
    acc = walk(form, in_safe?, acc)
    walk_children(args, in_safe?, acc)
  end

  defp walk({form, _meta, _atom}, in_safe?, acc), do: walk(form, in_safe?, acc)

  # 2-tuple — keyword pair, etc.
  defp walk({a, b}, in_safe?, acc) do
    acc = walk(a, in_safe?, acc)
    walk(b, in_safe?, acc)
  end

  defp walk(list, in_safe?, acc) when is_list(list), do: walk_children(list, in_safe?, acc)
  defp walk(_other, _in_safe?, acc), do: acc

  defp walk_children(list, in_safe?, acc) when is_list(list) do
    Enum.reduce(list, acc, fn child, a -> walk(child, in_safe?, a) end)
  end

  defp build_diagnostic(file, meta) do
    Diagnostic.error("5.52",
      title: "__STACKTRACE__ leaked across response boundary",
      message:
        "__STACKTRACE__ in a boundary module (controller / channel / LiveView / " <>
          "view / resolver) — internal call paths and module topology end up in " <>
          "the response visible to the caller.",
      why:
        "Stacktraces leak the internal module structure of the application: " <>
          "private modules, line numbers, library versions, and call paths. This " <>
          "is a roadmap for an attacker. Boundary modules must sanitize errors " <>
          "into bounded, opaque error codes (`%{code: \"internal_error\"}`).",
      alternatives: [
        Fix.new(
          summary: "Log the stacktrace, return a sanitized error",
          detail:
            "Move the stacktrace into Logger.error/1 (or :telemetry.execute) for " <>
              "internal observability, then return a domain error tuple " <>
              "({:error, :payment_failed}) which the boundary maps to a safe " <>
              "response shape (%{code: \"payment_failed\", message: \"...\"}).",
          applies_when: "The user error message can be derived without the stacktrace."
        ),
        Fix.new(
          summary: "Move the boundary's error formatting into a sanitizer module",
          detail:
            "Build `MyApp.Errors.sanitize/1` that maps every internal error " <>
              "({:error, :reason}, exception structs) to a stable external shape. " <>
              "The boundary calls only `sanitize/1`, never `__STACKTRACE__`.",
          applies_when: "Several controllers/channels share the same set of error mappings."
        )
      ],
      tags: [:security, :high],
      file: file,
      line: AST.line(meta)
    )
  end
end
