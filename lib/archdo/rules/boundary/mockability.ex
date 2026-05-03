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

  @doc """
  Project-level: scan all files for direct external IO usage,
  count behaviour definitions, and compute a mockability score.
  """
  def analyze_project(file_asts) do
    # Per-file: which external libraries does this file call directly?
    file_io =
      Enum.map(file_asts, fn {file, ast} ->
        caller = AST.extract_module_name(ast)
        {file, ast, find_external_io_calls(ast, caller), count_behaviours_used(ast)}
      end)

    # Direct IO surfaces: files that call external IO directly. Skip
    # adapter/test paths (filtered by file convention) and any module
    # the author has marked `@archdo_volatility :stable` — that marker
    # asserts the I/O is intentional CLI/infrastructure with no
    # substitutability seam needed.
    direct_io_files =
      Enum.filter(file_io, fn {file, ast, calls, _bhv} ->
        calls != [] and not adapter_or_test?(file) and
          not AST.has_marker?(ast, :archdo_volatility)
      end)

    # Behaviour surfaces: behaviour definitions in the project
    behaviour_count =
      Enum.sum(Enum.map(file_asts, fn {_file, ast} -> count_behaviour_definitions(ast) end))

    # Per-file diagnostics: each file with direct IO and no behaviour wrapper
    file_diagnostics =
      Enum.map(direct_io_files, fn {file, _ast, calls, _} ->
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
              summary:
                "Define a behaviour for each external library and inject the implementation",
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
      ratio = mockability_ratio(direct_count, behaviour_count)
      severity = mockability_severity(direct_count, ratio)
      passed_tags = mockability_tags(direct_count, ratio)
      message = mockability_message(direct_count, behaviour_count, ratio)
      suggestion = mockability_suggestion(direct_count, ratio)
      builder = Diagnostic.builder_for(severity)

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
            ratio:
              case ratio do
                :infinity -> nil
                r -> r
              end
          },
          tags: passed_tags,
          file: "project",
          line: 0
        )
      ]
    end
  end

  defp mockability_ratio(0, _), do: :infinity
  defp mockability_ratio(direct_count, behaviour_count), do: behaviour_count / direct_count

  defp mockability_severity(0, _), do: :info
  defp mockability_severity(_, :infinity), do: :info
  defp mockability_severity(_, ratio) when ratio < 0.3, do: :warning
  defp mockability_severity(_, _), do: :info

  # Fully-positive cases get :passed so summary tallies them in their own
  # column rather than as actionable info findings.
  defp mockability_tags(0, _), do: [:passed]
  defp mockability_tags(_, :infinity), do: [:passed]
  defp mockability_tags(_, _), do: []

  defp mockability_message(0, _, _),
    do: "Mockability: no direct external IO calls detected — fully mockable"

  defp mockability_message(_, behaviour_count, :infinity),
    do: "Mockability: #{behaviour_count} behaviour seams, 0 direct IO surfaces"

  defp mockability_message(direct_count, behaviour_count, ratio) do
    ratio_str = :erlang.float_to_binary(ratio * 1.0, decimals: 2)

    "Mockability: #{direct_count} direct IO surfaces vs #{behaviour_count} behaviour seams (ratio #{ratio_str})"
  end

  defp mockability_suggestion(0, _),
    do: "External IO is entirely behind behaviours — tests can mock everything via Mox"

  defp mockability_suggestion(_, :infinity),
    do: "All external IO is behind behaviours — ideal mockability"

  defp mockability_suggestion(_, ratio) when ratio < 0.3,
    do:
      "Many direct IO calls, few behaviour seams. Mocking real-world input is hard. Define behaviours for HTTP, email, etc."

  defp mockability_suggestion(_, ratio) when ratio < 0.7,
    do:
      "Some direct IO calls bypass behaviour seams. Aim for 1:1 — every IO library wrapped by a behaviour."

  defp mockability_suggestion(_, _),
    do:
      "Most external IO is behind behaviours. Look at the flagged files to find the remaining direct calls."

  defp find_external_io_calls(ast, caller_module) do
    Enum.map(
      AST.find_all(ast, fn
        {{:., _, [{:__aliases__, _, mod_parts}, _func]}, _meta, _args} ->
          mod_parts in @external_io_libraries and
            not AST.self_call?(caller_module, mod_parts)

        _ ->
          false
      end),
      fn {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _} ->
        {AST.module_name(Module.concat(mod_parts)), func, AST.line(meta)}
      end
    )
  end

  defp count_behaviours_used(ast) do
    length(
      AST.find_all(ast, fn
        {:@, _, [{:behaviour, _, _}]} -> true
        _ -> false
      end)
    )
  end

  defp count_behaviour_definitions(ast) do
    case length(
           AST.find_all(ast, fn
             {:@, _, [{:callback, _, _}]} -> true
             _ -> false
           end)
         ) do
      0 -> 0
      _ -> 1
    end
  end

  # Path fragments that classify a file as tooling/adapter/test rather
  # than domain code. Matched via `String.contains?` for substring
  # markers and `String.ends_with?` for filename-suffix markers.
  @adapter_substrings [
    "/test/",
    "/adapter",
    "/adapters/",
    "/clients/",
    "/infrastructure/",
    "/mix/",
    "/tasks/",
    "/hot_upgrade",
    "/seeds"
  ]

  @adapter_suffixes [
    "_client.ex",
    "_adapter.ex",
    "/mailer.ex",
    "/release.ex",
    "/helpers.ex"
  ]

  defp adapter_or_test?(file) do
    String.starts_with?(file, "test/") or
      Enum.any?(@adapter_substrings, &String.contains?(file, &1)) or
      Enum.any?(@adapter_suffixes, &String.ends_with?(file, &1))
  end
end
