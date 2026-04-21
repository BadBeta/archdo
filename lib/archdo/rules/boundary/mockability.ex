defmodule Archdo.Rules.Boundary.Mockability do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.8"

  @impl true
  def description, do: "Mockability — count of direct external IO surfaces vs behaviour seams"

  # External IO library prefixes — calls to these in domain code mean the
  # boundary leaks the library through to callers, making mocking hard.
  @external_io_libraries [
    # HTTP clients
    [:HTTPoison],
    [:Finch],
    [:Req],
    [:Tesla],
    [:Mint, :HTTP],
    # Email
    [:Swoosh],
    [:Bamboo],
    # AWS
    [:ExAws],
    # Payments
    [:Stripe],
    [:Stripity, :Stripe],
    # SMS
    [:ExTwilio],
    # File system at the high level
    [:File]
  ]

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: scan all files for direct external IO usage,
  count behaviour definitions, and compute a mockability score.
  """
  def analyze_project(file_asts) do
    # Per-file: which external libraries does this file call directly?
    file_io =
      Enum.map(file_asts, fn {file, ast} ->
        caller = AST.extract_module_name(ast)
        {file, find_external_io_calls(ast, caller), count_behaviours_used(ast)}
      end)

    # Direct IO surfaces: files that call external IO directly
    direct_io_files =
      Enum.filter(file_io, fn {file, calls, _bhv} ->
        calls != [] and not adapter_or_test?(file)
      end)

    # Behaviour surfaces: behaviour definitions in the project
    behaviour_count =
      Enum.sum(Enum.map(file_asts, fn {_file, ast} -> count_behaviour_definitions(ast) end))

    # Per-file diagnostics: each file with direct IO and no behaviour wrapper
    file_diagnostics =
      Enum.map(direct_io_files, fn {file, calls, _} ->
        unique_libraries =
          calls
          |> Enum.map(fn {lib, _, _} -> lib end)
          |> Enum.uniq()

        Diagnostic.info("4.8",
          title: "Direct external IO call",
          message:
            "#{Path.basename(file)} directly calls #{length(unique_libraries)} external IO libraries: #{Enum.join(unique_libraries, ", ")}",
          why:
            "Direct calls to HTTP/email/AWS/file libraries from non-adapter code make tests brittle: " <>
              "every test that touches this file must either hit the real service or globally monkey-patch " <>
              "the library. Wrapping each external dependency in a behaviour gives Mox a clean seam — tests " <>
              "swap one mock instead of many ad-hoc patches.",
          alternatives: [
            Fix.new(
              summary: "Define a behaviour for each external library and inject the implementation",
              detail:
                "For each library used here, declare a behaviour exposing only the operations this code needs. " <>
                  "Implement an adapter that delegates to the library, configure via Application env, and use " <>
                  "Mox in tests.",
              applies_when: "The external services are testable behind a small interface."
            ),
            Fix.new(
              summary: "Move the calls to a dedicated adapter module",
              detail:
                "If you already have an adapters/ namespace, move these calls there. The current file depends " <>
                  "on the adapter rather than the library, and the rule no longer fires.",
              applies_when: "An adapter pattern exists in the codebase."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#4.8"],
          context: %{libraries: unique_libraries},
          file: file,
          line: 1
        )
      end)

    # Project-level summary diagnostic
    summary = build_summary(direct_io_files, behaviour_count, length(file_asts))

    file_diagnostics ++ summary
  end

  defp build_summary(direct_io_files, behaviour_count, total_files) do
    direct_count = length(direct_io_files)

    if total_files == 0 do
      []
    else
      ratio =
        case direct_count do
          0 -> :infinity
          n -> behaviour_count / n
        end

      severity =
        cond do
          direct_count == 0 -> :info
          ratio == :infinity -> :info
          ratio < 0.3 -> :warning
          ratio < 0.7 -> :info
          true -> :info
        end

      message =
        cond do
          direct_count == 0 ->
            "Mockability: no direct external IO calls detected — fully mockable"

          ratio == :infinity ->
            "Mockability: #{behaviour_count} behaviour seams, 0 direct IO surfaces"

          true ->
            ratio_str = :erlang.float_to_binary(ratio * 1.0, decimals: 2)

            "Mockability: #{direct_count} direct IO surfaces vs #{behaviour_count} behaviour seams (ratio #{ratio_str})"
        end

      suggestion =
        cond do
          direct_count == 0 ->
            "External IO is entirely behind behaviours — tests can mock everything via Mox"

          ratio == :infinity ->
            "All external IO is behind behaviours — ideal mockability"

          ratio < 0.3 ->
            "Many direct IO calls, few behaviour seams. Mocking real-world input is hard. Define behaviours for HTTP, email, etc."

          ratio < 0.7 ->
            "Some direct IO calls bypass behaviour seams. Aim for 1:1 — every IO library wrapped by a behaviour."

          true ->
            "Most external IO is behind behaviours. Look at the flagged files to find the remaining direct calls."
        end

      builder =
        case severity do
          :warning -> &Diagnostic.warning/2
          _ -> &Diagnostic.info/2
        end

      [
        builder.("4.8",
          title: "Project mockability summary",
          message: message,
          why:
            "A healthy mockability ratio means almost every external dependency has a behaviour seam. When " <>
              "the ratio is low (many direct IO calls, few behaviours), tests can't swap dependencies cleanly " <>
              "and end up either hitting real services or duct-taping global mocks. The summary shows where " <>
              "the project sits on that spectrum.",
          alternatives: [
            Fix.new(
              summary: suggestion,
              detail:
                "See the per-file diagnostics above for the specific files that need a behaviour wrapper. " <>
                  "Aim for a 1:1 ratio between behaviour seams and external IO surfaces.",
              applies_when: "Improving overall mockability."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#4.8"],
          context: %{
            direct_io_count: direct_count,
            behaviour_count: behaviour_count,
            ratio: (case ratio do :infinity -> nil; r -> r end)
          },
          file: "project",
          line: 0
        )
      ]
    end
  end

  defp find_external_io_calls(ast, caller_module) do
    Enum.map(AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, mod_parts}, _func]}, _meta, _args} ->
        mod_parts in @external_io_libraries and
          not AST.self_call?(caller_module, mod_parts)

      _ ->
        false
    end), fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
      {AST.module_name(Module.concat(mod_parts)), func, AST.line(meta)}
    end)
  end

  defp count_behaviours_used(ast) do
    length(AST.find_all(ast, fn
      {:@, _, [{:behaviour, _, _}]} -> true
      _ -> false
    end))
  end

  defp count_behaviour_definitions(ast) do
    case length(AST.find_all(ast, fn
      {:@, _, [{:callback, _, _}]} -> true
      _ -> false
    end)) do
      0 -> 0
      _ -> 1
    end
  end

  defp adapter_or_test?(file) do
    String.contains?(file, "/test/") or
      String.starts_with?(file, "test/") or
      String.contains?(file, "/adapter") or
      String.contains?(file, "/adapters/") or
      String.contains?(file, "/clients/") or
      String.contains?(file, "/infrastructure/") or
      String.ends_with?(file, "_client.ex") or
      String.ends_with?(file, "_adapter.ex") or
      String.ends_with?(file, "/mailer.ex") or
      # Tooling — not domain code
      String.contains?(file, "/mix/") or
      String.contains?(file, "/tasks/") or
      String.ends_with?(file, "/release.ex") or
      String.ends_with?(file, "/helpers.ex") or
      String.contains?(file, "/hot_upgrade") or
      String.contains?(file, "/seeds")
  end
end
