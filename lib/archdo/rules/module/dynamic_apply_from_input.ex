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
  def cleanup_pass, do: 6

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true ->
        []

      false ->
        # Pre-pass 1: collect every 3-tuple variable-destructure
        # pattern in the file. `{m, f, a}` patterns are the OTP
        # MFA-tuple convention (Supervisor child specs, GenServer
        # start_link, every DSL accepting "call this MFA"). When
        # an `apply(m, f, a)` uses variables matching such a
        # destructure, the values come from a structured tuple in
        # config/DSL — not user input. Suppress the diagnostic.
        mfa_triples = collect_mfa_destructures(ast)

        # Pre-pass 2: collect line numbers where `apply/N` appears as
        # the HEAD of a def/defp/defmacro/defmacrop or under @spec /
        # @callback. The AST node `{:apply, meta, [args]}` has the
        # same shape whether it's a call or a function-head, so we
        # disambiguate structurally during a pre-pass and suppress
        # findings at those line numbers. Real-world: linear-algebra
        # operator modules define `def apply(op, a, b)` to apply an
        # operator struct to arguments — the function head is named
        # `apply`, not a call to Kernel.apply.
        def_apply_lines = collect_def_apply_lines(ast)

        {_, hits} =
          Macro.prewalk(ast, [], fn node, acc ->
            collect(node, acc, file, mfa_triples, def_apply_lines)
          end)

        Enum.reverse(hits)
    end
  end

  # Pre-pass 2 — line numbers where `apply/N` is a def/defp head OR
  # appears under @spec / @callback. Suppress findings at those lines.
  defp collect_def_apply_lines(ast) do
    {_, lines} =
      Macro.prewalk(ast, MapSet.new(), fn
        # def apply(...) / defp apply(...) / defmacro apply(...) — possibly with body
        {kind, _, [{:apply, head_meta, args} | _]} = node, acc
        when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(args) ->
          {node, MapSet.put(acc, AST.line(head_meta))}

        # def apply(...) when guard
        {kind, _, [{:when, _, [{:apply, head_meta, args} | _]} | _]} = node, acc
        when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(args) ->
          {node, MapSet.put(acc, AST.line(head_meta))}

        # @spec apply(...) :: ret  /  @callback apply(...) :: ret
        {:@, _, [{attr, _, [{:"::", _, [{:apply, head_meta, args}, _]}]}]} = node, acc
        when attr in [:spec, :callback] and is_list(args) ->
          {node, MapSet.put(acc, AST.line(head_meta))}

        node, acc ->
          {node, acc}
      end)

    lines
  end

  # Walk the AST collecting every 3-element variable-only tuple
  # pattern: `{var1, var2, var3}` where all three are bare variable
  # references. AST shape: `{:{}, _, [{n1, _, _}, {n2, _, _}, {n3, _, _}]}`.
  # Returns a MapSet of `{n1, n2}` PAIRS (module + function names) —
  # we don't constrain on the third position because MFA invocations
  # are commonly augmented: `apply(m, f, [extra | a])` adds a prefix
  # to the args before applying.
  defp collect_mfa_destructures(ast) do
    {_, pairs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:{}, _, [{n1, _, c1}, {n2, _, c2}, {n3, _, c3}]} = node, acc
        when is_atom(n1) and is_atom(n2) and is_atom(n3) and
               (is_atom(c1) or is_nil(c1)) and (is_atom(c2) or is_nil(c2)) and
               (is_atom(c3) or is_nil(c3)) ->
          {node, MapSet.put(acc, {n1, n2})}

        node, acc ->
          {node, acc}
      end)

    pairs
  end

  # §§ elixir-implementing: §5.2, §7.6 — multi-clause head dispatch on AST shape.

  # Kernel.apply/3 — alias form. The `Kernel.` prefix disambiguates a call
  # from a `def apply` head, so no line-skip needed here.
  defp collect(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, meta, [mod, fun, args]} = node,
         acc,
         file,
         mfa,
         _def_lines
       ) do
    classify_apply3(node, acc, file, meta, mod, fun, args, mfa)
  end

  # apply/3 — auto-imported Kernel form. AST shape `{:apply, _, [a,b,c]}`
  # is also produced by `def apply(a, b, c)` heads — skip those.
  defp collect({:apply, meta, [mod, fun, args]} = node, acc, file, mfa, def_lines) do
    case MapSet.member?(def_lines, AST.line(meta)) do
      true -> {node, acc}
      false -> classify_apply3(node, acc, file, meta, mod, fun, args, mfa)
    end
  end

  # apply/2 — function form. Same head-vs-call ambiguity.
  defp collect({:apply, meta, [fun, _args]} = node, acc, file, _mfa, def_lines)
       when not is_nil(meta) do
    cond do
      MapSet.member?(def_lines, AST.line(meta)) -> {node, acc}
      literal_fun_ref?(fun) -> {node, acc}
      true -> {node, [diag_apply2(file, meta) | acc]}
    end
  end

  defp collect(node, acc, _file, _mfa, _def_lines), do: {node, acc}

  defp classify_apply3(node, acc, file, meta, mod, fun, args, mfa) do
    cond do
      mfa_passthrough?(mod, fun, args, mfa) ->
        {node, acc}

      literal_module?(mod) and (literal_atom?(fun) or phoenix_action_name?(fun)) ->
        {node, acc}

      not literal_module?(mod) ->
        {node, [diag_apply3_module(file, meta) | acc]}

      true ->
        {node, [diag_apply3_function(file, meta) | acc]}
    end
  end

  # `apply(m, f, a)` where m, f are bare variables and `{m, f, _}` is
  # destructured as a 3-tuple somewhere in the file — the standard
  # OTP MFA-tuple convention (Supervisor child spec, GenServer
  # start_link, every DSL accepting "call this MFA"). The args
  # position can be the bare `a` or an augmented form like
  # `[extra | a]` — both are recognised since the M/F-from-tuple
  # signal is the discriminator.
  defp mfa_passthrough?(mod, fun, _args, mfa_pairs) do
    case {var_name(mod), var_name(fun)} do
      {m, f} when is_atom(m) and is_atom(f) -> MapSet.member?(mfa_pairs, {m, f})
      _ -> false
    end
  end

  defp var_name({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)),
    do: name

  defp var_name({:__block__, _, [inner]}), do: var_name(inner)
  defp var_name(_), do: nil

  # Phoenix's documented controller-action injection pattern:
  # `apply(__MODULE__, action_name(conn), args)` from a `def action/2`
  # callback. `Phoenix.Controller.action_name/1` reads
  # `conn.private.phoenix_action`, set by Phoenix's router based on
  # the matched route — NOT user input. Documented at
  # https://hexdocs.pm/phoenix/Phoenix.Controller.html#action/2 as the
  # standard way to inject pre-loaded resources into actions.
  defp phoenix_action_name?({:action_name, _, [_]}), do: true

  defp phoenix_action_name?(
         {{:., _, [{:__aliases__, _, [:Phoenix, :Controller]}, :action_name]}, _, [_]}
       ),
       do: true

  defp phoenix_action_name?({:__block__, _, [inner]}), do: phoenix_action_name?(inner)
  defp phoenix_action_name?(_), do: false

  # §§ elixir-implementing: §7.4 — exact AST shape match. A "literal module"
  # is a compile-time-known module reference. Any of: __aliases__, __MODULE__,
  # or an atom literal whose value starts uppercase or names a known atom
  # module (e.g. `:erlang`, `:gen_server`).
  defp literal_module?({:__aliases__, _, _}), do: true
  defp literal_module?({:__MODULE__, _, _}), do: true
  defp literal_module?({:__block__, _, [inner]}), do: literal_module?(inner)
  defp literal_module?(atom) when is_atom(atom), do: true
  defp literal_module?({:unquote, _, _}), do: true
  defp literal_module?(_), do: false

  defp literal_atom?({:__block__, _, [inner]}), do: literal_atom?(inner)
  defp literal_atom?(atom) when is_atom(atom), do: true
  defp literal_atom?({:unquote, _, _}), do: true
  defp literal_atom?(_), do: false

  # Function-reference literals: `&Mod.fun/2` capture, anonymous `fn ... end`,
  # or a literal atom (rare — Erlang local-fun reference).
  # `unquote(...)` is also accepted: inside a macro context it resolves
  # to a compile-time-determined value from the surrounding `for`/list,
  # not a user-controlled runtime dispatch.
  # `{:__block__, _, [inner]}` is the production parser's literal-encoder
  # wrap and unwraps to the underlying form.
  defp literal_fun_ref?({:__block__, _, [inner]}), do: literal_fun_ref?(inner)
  defp literal_fun_ref?({:&, _, _}), do: true
  defp literal_fun_ref?({:fn, _, _}), do: true
  defp literal_fun_ref?(atom) when is_atom(atom), do: true
  defp literal_fun_ref?({:unquote, _, _}), do: true
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
