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
      _ -> Enum.flat_map(file_asts, &module_diagnostics(&1, paths))
    end
  end

  defp module_diagnostics({file, ast}, paths) do
    cond do
      AST.test_file?(file) -> []
      not AST.path_starts_with_any?(file, paths) -> []
      AST.has_marker?(ast, :archdo_no_trace) -> []
      module_level_trace?(ast) -> []
      true -> find_untraced_publics(file, ast)
    end
  end

  # True when @requirement / @spec_ref / @trace appears BEFORE any def
  # in the module body. Such an attribute covers every public function;
  # attributes between or right before defs are function-level.
  defp module_level_trace?(ast) do
    body = AST.module_body(ast)

    Enum.reduce_while(body, false, fn
      {:def, _, _}, _ -> {:halt, false}
      {:@, _, [{name, _, _}]}, _ when name in @trace_attrs -> {:halt, true}
      _, acc -> {:cont, acc}
    end)
  end

  # Walk module body in order; @requirement / @spec_ref / @trace
  # immediately before a def covers that def. Otherwise, the def is
  # untraced.
  defp find_untraced_publics(file, ast) do
    body = AST.module_body(ast)
    module = AST.extract_module_name(ast)

    {diags, _pending} =
      Enum.reduce(body, {[], false}, fn node, acc ->
        absorb_trace_walk(trace_walk_kind(node), node, acc, file, module)
      end)

    Enum.reverse(diags)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the classifier tag (trace attribute / public def / other) and
  # the pending_trace? boolean.
  defp trace_walk_kind(node) do
    cond do
      trace_attr?(node) -> :trace_attr
      AST.def_node?(node) -> :public_def
      true -> :other
    end
  end

  defp absorb_trace_walk(:trace_attr, _node, {acc, _pending}, _file, _module), do: {acc, true}

  defp absorb_trace_walk(:public_def, node, {acc, pending_trace?}, file, module) do
    record_def_diag(pending_trace?, acc, file, module, name_arity_meta(node))
  end

  defp absorb_trace_walk(:other, _node, acc, _file, _module), do: acc

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the pending_trace? boolean. The {n, a, meta} 3-tuple stays intact
  # all the way to the diagnostic call, no separate destructure.
  defp record_def_diag(true, acc, _file, _module, _name_arity_meta), do: {acc, false}

  defp record_def_diag(false, acc, file, module, {n, a, meta}),
    do: {[build_diagnostic(file, module, n, a, meta) | acc], false}

  defp trace_attr?({:@, _, [{name, _, _}]}) when name in @trace_attrs, do: true
  defp trace_attr?(_), do: false

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
            ~s|`@requirement "REQ-1234"` or `@requirement ["REQ-1234", "REQ-1235"]` for multiple. Place above the `def`. For external standards: `@spec_ref "RFC 7231 §6.5.1"`. For composite trace: `@trace ~w(REQ-1234 ADR-0042)`.|,
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
