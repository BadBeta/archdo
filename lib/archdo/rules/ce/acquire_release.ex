defmodule Archdo.Rules.CE.AcquireRelease do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-21. A module exposing paired
  # acquire/release public functions (`open`/`close`,
  # `acquire`/`release`, `subscribe`/`unsubscribe`, etc.) without a
  # bracket-style helper (`with_X/2` taking a callback). Connascence
  # of execution between two distant call sites — every caller must
  # remember to pair the calls and handle the cleanup branch on
  # exception. Forgotten releases leak resources; orphaned locks
  # deadlock.

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "CE-21"

  @impl true
  def description, do: "Acquire/release public function pair without a `with_X/2` bracket helper"

  # Recognized acquire/release name pairs. Each entry is `{open, close}`.
  @pairs [
    {:open, :close},
    {:acquire, :release},
    {:subscribe, :unsubscribe},
    {:lock, :unlock},
    {:connect, :disconnect},
    {:checkout, :checkin}
  ]

  # Long-lived process pairs that the OTP supervision tree handles —
  # not the bracket pattern's territory.
  @process_lifecycle_pairs [{:start_link, :stop}, {:start, :stop}]

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_unbracketed_pairs(file, ast)
    end
  end

  defp find_unbracketed_pairs(file, ast) do
    public_fns =
      ast
      |> AST.extract_functions(:public)
      |> Enum.map(fn {name, _arity, _meta, _args, _body} -> name end)
      |> MapSet.new()

    line = first_line(ast)

    @pairs
    |> Enum.filter(fn {open, close} ->
      MapSet.member?(public_fns, open) and
        MapSet.member?(public_fns, close) and
        not has_bracket_helper?(public_fns, open) and
        not lifecycle_pair?({open, close})
    end)
    |> Enum.map(fn {open, close} -> build_diagnostic(file, line, open, close) end)
  end

  defp lifecycle_pair?(pair), do: pair in @process_lifecycle_pairs

  # A bracket helper is any function named `with_X` where X mirrors
  # the resource name (often the module's domain). Lenient detection:
  # any public function whose name starts with `with_` qualifies.
  defp has_bracket_helper?(public_fns, _open) do
    Enum.any?(public_fns, fn name ->
      name |> Atom.to_string() |> String.starts_with?("with_")
    end)
  end

  defp first_line(ast) do
    case AST.find_all(ast, fn
           {:defmodule, _, _} -> true
           _ -> false
         end) do
      [{:defmodule, meta, _} | _] -> AST.line(meta)
      _ -> 1
    end
  end

  defp build_diagnostic(file, line, open, close) do
    Diagnostic.info("CE-21",
      title: "Acquire/release pair without bracket helper",
      message:
        "Module exposes #{open}/#{close} public pair without a `with_*` bracket " <>
          "helper that pairs them",
      why:
        "Every caller must remember to pair the calls and handle the cleanup " <>
          "branch on exception. Forgotten releases leak resources; orphaned " <>
          "locks deadlock. The pair is connascence of execution between two " <>
          "distant call sites.",
      alternatives: [
        Fix.new(
          summary: "Add a bracket helper that pairs acquire + release",
          detail:
            "Provide a `with_*/2` (or similarly-named) function: " <>
              "`def with_resource(arg, fun) do; r = #{open}(arg); try do; " <>
              "fun.(r); after; #{close}(r); end; end`. Most callers can switch " <>
              "to the bracket; only callers needing manual control retain the " <>
              "raw pair.",
          applies_when:
            "Resource lifecycle is bounded by a single function scope at the call site."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-21"],
      context: %{open: open, close: close},
      file: file,
      line: line
    )
  end
end
