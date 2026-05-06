defmodule Archdo.Rules.Module.DefdelegateOpportunity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.AST.Unwrap

  @impl true
  def id, do: "6.86"

  @impl true
  def description,
    do: "Public 1-line forward to another module — use `defdelegate`"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_violations(file, ast)
    end
  end

  defp find_violations(file, ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [head, kw_or_body]} = node, acc ->
          {node, maybe_collect(meta, head, kw_or_body, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.map(hits, fn {line, target_mod, target_fun} ->
      build_diagnostic(file, line, target_mod, target_fun)
    end)
  end

  defp maybe_collect(meta, head, kw_or_body, acc) do
    case forward_only?(head, kw_or_body) do
      {:ok, target_mod, target_fun} -> [{AST.line(meta), target_mod, target_fun} | acc]
      :no -> acc
    end
  end

  # Head pattern: `name(arg1, arg2, ...)` where each argi is a bare
  # variable (no destructure, no default, no guard). Body: a single
  # remote call `Mod.fun(arg1, arg2, ...)` with the args passed
  # through unchanged in same order. Result: defdelegate eligible.
  defp forward_only?({:when, _, _}, _), do: :no

  defp forward_only?({fn_name, _, head_args}, kw_or_body)
       when is_atom(fn_name) and is_list(head_args) do
    case all_bare_vars(head_args) do
      true -> check_body(kw_or_body, head_args)
      false -> :no
    end
  end

  defp forward_only?(_, _), do: :no

  defp all_bare_vars(args) do
    Enum.all?(args, fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> true
      _ -> false
    end)
  end

  defp check_body(kw, head_args) when is_list(kw) do
    case extract_body(kw) do
      nil -> :no
      body -> check_single_remote_call(body, head_args)
    end
  end

  defp check_body(body, head_args), do: check_single_remote_call(body, head_args)

  defp extract_body(kw) do
    case Unwrap.kw_get(kw, :do) do
      {:ok, body} -> body
      :error -> nil
    end
  end

  defp check_single_remote_call(
         {{:., _, [{:__aliases__, _, mod_parts}, fun]}, _, call_args},
         head_args
       )
       when is_atom(fun) and is_list(call_args) do
    case args_match?(head_args, call_args) do
      true -> {:ok, mod_parts, fun}
      false -> :no
    end
  end

  defp check_single_remote_call(_, _), do: :no

  # Strict equality of head arg names with call arg names (in order).
  # Element-wise recursion: same shape, same name, same atomic-context.
  defp args_match?([], []), do: true

  defp args_match?(
         [{name, _, h_ctx} | h_rest],
         [{name, _, c_ctx} | c_rest]
       )
       when is_atom(name) and is_atom(h_ctx) and is_atom(c_ctx) do
    args_match?(h_rest, c_rest)
  end

  defp args_match?(_, _), do: false

  defp build_diagnostic(file, line, target_mod, target_fun) do
    target = "#{Enum.join(target_mod, ".")}.#{target_fun}"

    Diagnostic.info("6.86",
      title: "Public 1-line forward — use `defdelegate`",
      message:
        "This `def` forwards every argument unchanged to `#{target}`. `defdelegate` " <>
          "expresses the forward more directly and gets `@spec` / `@doc` from the target.",
      why:
        "`defdelegate name(args), to: Mod` is exactly this case. The hand-written `def f(x), " <>
          "do: Mod.f(x)` form duplicates the call signature inline; defdelegate documents " <>
          "the forwarding intent and is a single line.",
      alternatives: [
        Fix.new(
          summary: "Replace with defdelegate",
          detail: "defdelegate get_product!(id), to: MyApp.Catalog.Product, as: :fetch!",
          applies_when:
            "When the public function is purely a forward (no telemetry / logging / " <>
              "transformation in the body)."
        )
      ],
      references: ["elixir-implementing/SKILL.md#2.7"],
      context: %{target: target},
      file: file,
      line: line
    )
  end
end
