defmodule Archdo.Rules.CE.MissingTraceability do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — CE-32. Public functions on traceability-
  # required paths without an `@requirement`, `@spec_ref`, or `@trace`
  # annotation. Opt-in: off by default; on for regulated / safety-
  # critical / contractually-traceable codebases. Pack:
  # `:ce_compliance` — only fires when packs include it AND
  # `traceability_required_paths` is configured.

  alias Archdo.{AST, Diagnostic, Fix}

  @trace_attrs [:requirement, :spec_ref, :trace]

  @impl true
  def id, do: "CE-32"

  @impl true
  def description,
    do: "Public function on traceability path lacks @requirement / @spec_ref / @trace"

  @impl true
  def pack, do: :ce_compliance

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level. Returns one Diagnostic per untraced public function
  on a traceability-required path. Off by default — `opts` must
  include `traceability_required_paths: [path_prefix, ...]`.
  """
  @spec analyze_project([{String.t(), Macro.t()}], keyword()) :: [Diagnostic.t()]
  def analyze_project(file_asts, opts \\ []) do
    paths = Keyword.get(opts, :traceability_required_paths, [])

    case paths do
      [] -> []
      _ -> file_asts |> Enum.flat_map(&module_diagnostics(&1, paths))
    end
  end

  defp module_diagnostics({file, ast}, paths) do
    cond do
      AST.test_file?(file) -> []
      not under_traceability_path?(file, paths) -> []
      no_trace_marker?(ast) -> []
      module_level_trace?(ast) -> []
      true -> find_untraced_publics(file, ast)
    end
  end

  defp under_traceability_path?(file, paths) do
    Enum.any?(paths, &String.starts_with?(file, &1))
  end

  defp no_trace_marker?(ast) do
    AST.contains?(ast, fn
      {:@, _, [{:archdo_no_trace, _, _}]} -> true
      _ -> false
    end)
  end

  # True when @requirement / @spec_ref / @trace appears BEFORE any def
  # in the module body. Such an attribute covers every public function;
  # attributes between or right before defs are function-level.
  defp module_level_trace?(ast) do
    body = module_body(ast)

    Enum.reduce_while(body, false, fn
      {:def, _, _}, _ -> {:halt, false}
      {:@, _, [{name, _, _}]}, _ when name in @trace_attrs -> {:halt, true}
      _, acc -> {:cont, acc}
    end)
  end

  defp module_body({:defmodule, _, [_alias, kw]}) when is_list(kw) do
    case do_body(kw) do
      {:__block__, _, statements} -> statements
      single when single != nil -> [single]
      nil -> []
    end
  end

  defp module_body(_), do: []

  defp do_body(kw) do
    Enum.find_value(kw, fn
      {:do, body} -> body
      {{:__block__, _, [:do]}, body} -> body
      _ -> nil
    end)
  end

  # Walk module body in order; @requirement / @spec_ref / @trace
  # immediately before a def covers that def. Otherwise, the def is
  # untraced.
  defp find_untraced_publics(file, ast) do
    body = module_body(ast)
    module = AST.extract_module_name(ast)

    {diags, _pending} =
      Enum.reduce(body, {[], false}, fn node, {acc, pending_trace?} ->
        cond do
          trace_attr?(node) ->
            {acc, true}

          public_def?(node) ->
            {n, a, meta} = name_arity_meta(node)

            case pending_trace? do
              true -> {acc, false}
              false -> {[build_diagnostic(file, module, n, a, meta) | acc], false}
            end

          true ->
            {acc, pending_trace?}
        end
      end)

    Enum.reverse(diags)
  end

  defp trace_attr?({:@, _, [{name, _, _}]}) when name in @trace_attrs, do: true
  defp trace_attr?(_), do: false

  defp public_def?({:def, _, [{name, _, args} | _]}) when is_atom(name) and (is_list(args) or args == nil), do: true
  defp public_def?({:def, _, [{:when, _, [{name, _, args} | _]} | _]}) when is_atom(name) and (is_list(args) or args == nil), do: true
  defp public_def?(_), do: false

  defp name_arity_meta({:def, meta, [{name, _, args} | _]}) when is_atom(name),
    do: {name, length(args || []), meta}

  defp name_arity_meta({:def, meta, [{:when, _, [{name, _, args} | _]} | _]}) when is_atom(name),
    do: {name, length(args || []), meta}

  defp build_diagnostic(file, module, name, arity, meta) do
    Diagnostic.warning("CE-32",
      title: "Public function lacks requirement annotation",
      message:
        "#{module}.#{name}/#{arity}: on traceability-required path without " <>
          "@requirement / @spec_ref / @trace annotation",
      why:
        "In regulated industries (medical device per IEC 62304, aviation per " <>
          "DO-178C, automotive per ISO 26262, financial controls under SOX), every " <>
          "line of code must trace to an approved requirement. Beyond compliance, " <>
          "the discipline forces deliberate intent: the act of writing the " <>
          "requirement reference makes 'why does this code exist?' an explicit " <>
          "authorial decision rather than implicit accumulation.",
      alternatives: [
        Fix.new(
          summary: "Add @requirement immediately before the function",
          detail:
            "`@requirement \"REQ-1234\"` or `@requirement [\"REQ-1234\", " <>
              "\"REQ-1235\"]` for multiple. Place above the `def`. For external " <>
              "standards: `@spec_ref \"RFC 7231 §6.5.1\"`. For composite trace: " <>
              "`@trace ~w(REQ-1234 ADR-0042)`.",
          applies_when: "A requirement covers this function."
        ),
        Fix.new(
          summary: "Add module-level @requirement to cover the whole module",
          detail:
            "If every function in the module implements the same requirement, " <>
              "place `@requirement \"REQ-1234\"` at the top of the module body. " <>
              "Per-function annotations override.",
          applies_when: "The module has a single owning requirement."
        ),
        Fix.new(
          summary: "Mark @archdo_no_trace if the code shouldn't exist long-term",
          detail:
            "If the function is temporary scaffolding with a deletion deadline: " <>
              "`@archdo_no_trace \"WIP — delete by 2026-Q3\"` at module level.",
          applies_when: "The function is intentionally untraced and short-lived."
        )
      ],
      references: ["ARCHITECTURE_RULES_CHANGE_ECONOMY.md#CE-32"],
      context: %{module: module, function: "#{name}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
