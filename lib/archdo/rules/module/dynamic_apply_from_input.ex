defmodule Archdo.Rules.Module.DynamicApplyFromInput do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.51"

  @impl true
  def description,
    do: "Dynamic apply/2,3 with non-literal module or function — RCE if input flows from outside"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_dynamic_apply(ast, file)
    end
  end

  defp find_dynamic_apply(ast, file) do
    {_, hits} = Macro.prewalk(ast, [], fn node, acc -> collect(node, acc, file) end)
    Enum.reverse(hits)
  end

  # §§ elixir-implementing: §5.2, §7.6 — multi-clause head dispatch on AST shape.

  # Kernel.apply/3 — alias form
  defp collect(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, meta, [mod, fun, _args]} = node,
         acc,
         file
       ) do
    classify_apply3(node, acc, file, meta, mod, fun)
  end

  # apply/3 — auto-imported Kernel form
  defp collect({:apply, meta, [mod, fun, _args]} = node, acc, file) do
    classify_apply3(node, acc, file, meta, mod, fun)
  end

  # apply/2 — function form
  defp collect({:apply, meta, [fun, _args]} = node, acc, file) when not is_nil(meta) do
    case literal_fun_ref?(fun) do
      true -> {node, acc}
      false -> {node, [diag_apply2(file, meta) | acc]}
    end
  end

  defp collect(node, acc, _file), do: {node, acc}

  defp classify_apply3(node, acc, file, meta, mod, fun) do
    case {literal_module?(mod), literal_atom?(fun)} do
      {true, true} -> {node, acc}
      {false, _} -> {node, [diag_apply3_module(file, meta) | acc]}
      {true, false} -> {node, [diag_apply3_function(file, meta) | acc]}
    end
  end

  # §§ elixir-implementing: §7.4 — exact AST shape match. A "literal module"
  # is a compile-time-known module reference. Any of: __aliases__, __MODULE__,
  # or an atom literal whose value starts uppercase or names a known atom
  # module (e.g. `:erlang`, `:gen_server`).
  defp literal_module?({:__aliases__, _, _}), do: true
  defp literal_module?({:__MODULE__, _, _}), do: true
  defp literal_module?(atom) when is_atom(atom), do: true
  defp literal_module?(_), do: false

  defp literal_atom?(atom) when is_atom(atom), do: true
  defp literal_atom?(_), do: false

  # Function-reference literals: `&Mod.fun/2` capture, anonymous `fn ... end`,
  # or a literal atom (rare — Erlang local-fun reference).
  defp literal_fun_ref?({:&, _, _}), do: true
  defp literal_fun_ref?({:fn, _, _}), do: true
  defp literal_fun_ref?(atom) when is_atom(atom), do: true
  defp literal_fun_ref?(_), do: false

  defp diag_apply3_module(file, meta) do
    Diagnostic.error("5.51",
      title: "apply/3 with non-literal module",
      message:
        "apply(mod, fun, args) where `mod` is a variable or computed expression. " <>
          "If `mod` can be reached by external input (controller param, channel " <>
          "message, Oban arg), this is a remote-code-execution vector.",
      why:
        "Dynamic dispatch on a non-literal module name allows the caller to invoke " <>
          "any module loaded in the BEAM. Combined with `String.to_existing_atom/1` " <>
          "on user input, this is a complete RCE primitive. Even when the immediate " <>
          "input is internal, the module variable adds a hard-to-audit indirection.",
      alternatives: [
        Fix.new(
          summary: "Dispatch through a bounded registry",
          detail:
            "Define `@modules %{\"name\" => MyApp.RealModule}` and use " <>
              "`Map.fetch(@modules, name)` to look up the module. Unknown names " <>
              "return `{:error, :unknown}` instead of executing arbitrary code.",
          applies_when: "You need to choose between a known set of modules at runtime."
        ),
        Fix.new(
          summary: "Use a behaviour with config-driven implementation",
          detail:
            "Define a `@callback` behaviour and pick the implementation via " <>
              "`Application.compile_env!(:my_app, :impl)`. The implementation is " <>
              "fixed at compile time; tests swap via Mox.",
          applies_when:
            "The module choice is configured per environment (test/prod), not per request."
        )
      ],
      tags: [:security, :critical],
      file: file,
      line: AST.line(meta)
    )
  end

  defp diag_apply3_function(file, meta) do
    Diagnostic.error("5.51",
      title: "apply/3 with non-literal function name",
      message:
        "apply(KnownMod, fun, args) where `fun` is a variable. If `fun` reaches " <>
          "from external input, the caller can invoke any function on the module — " <>
          "including private helpers and unsafe operations.",
      why:
        "All public AND private functions on the target module are reachable via " <>
          "`apply/3` with a dynamic function name. Even private functions you " <>
          "thought were internal can be invoked. This is a confused-deputy attack: " <>
          "the caller controls what the module does.",
      alternatives: [
        Fix.new(
          summary: "Dispatch through a bounded action map",
          detail:
            "Define `@actions %{\"name\" => &Mod.real_fun/n}` and use " <>
              "`Map.fetch(@actions, name)`. The map is the explicit security " <>
              "boundary — only listed functions are reachable.",
          applies_when: "You need to choose between a known set of operations at runtime."
        ),
        Fix.new(
          summary: "Use a multi-clause function as the dispatcher",
          detail:
            "Replace `apply(Mod, fun, args)` with explicit clauses: " <>
              "`def run(\"name\", args), do: Mod.real_fun(args); def run(_, _), " <>
              "do: {:error, :unknown}`.",
          applies_when: "The set of operations is small enough that explicit clauses are clearer."
        )
      ],
      tags: [:security, :critical],
      file: file,
      line: AST.line(meta)
    )
  end

  defp diag_apply2(file, meta) do
    Diagnostic.error("5.51",
      title: "apply/2 with non-literal function reference",
      message:
        "apply(fun, args) where `fun` is a variable. If `fun` flows from external " <>
          "input or a registry that accepts external keys, the caller controls what " <>
          "code runs.",
      why:
        "apply/2 invokes a function reference. A variable function reference can " <>
          "point at any function on any module — same RCE risk as dynamic apply/3.",
      alternatives: [
        Fix.new(
          summary: "Use a bounded registry of function captures",
          detail:
            "Define `@actions %{\"name\" => &Mod.run/2}` and look up the capture " <>
              "with `Map.fetch(@actions, name)`. The map is the security boundary.",
          applies_when: "You need runtime dispatch between a known set of function captures."
        )
      ],
      tags: [:security, :critical],
      file: file,
      line: AST.line(meta)
    )
  end
end
