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

        # §§ M-fb-F3 — Pre-pass 3: collect variable names bound from
        # `Application.{get_env, fetch_env, fetch_env!, compile_env,
        # compile_env!}`. When `apply(mod, ...)` uses one of these
        # bindings, the module source is operator-controlled config
        # (deploy-time .exs files), NOT request input. Per
        # `elixir-implementing` §1 rule 31 this is the canonical Plug
        # pattern — downgrade the diagnostic from :error to :warning
        # so reviewers still see it but the severity matches the risk.
        operator_config_vars = collect_operator_config_vars(ast)

        {_, hits} =
          Macro.prewalk(ast, [], fn node, acc ->
            collect(node, acc, file, mfa_triples, def_apply_lines, operator_config_vars)
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
  # §§ M-fb-F3 — collect var names whose RHS is a call to
  # `Application.{get_env, fetch_env, fetch_env!, compile_env,
  # compile_env!}`. Two AST shapes:
  #   1. `mod = Application.get_env(:app, :key)` — direct binding.
  #   2. `{:ok, mod} = Application.fetch_env(:app, :key)` — tuple destructure.
  # The returned MapSet holds bare variable names (atoms).
  @operator_config_funs [:get_env, :fetch_env, :fetch_env!, :compile_env, :compile_env!]

  defp collect_operator_config_vars(ast) do
    {_, names} =
      Macro.prewalk(ast, MapSet.new(), fn node, acc ->
        case operator_config_binding(node) do
          [] -> {node, acc}
          vars -> {node, Enum.reduce(vars, acc, &MapSet.put(&2, &1))}
        end
      end)

    names
  end

  # `mod = Application.<fun>(...)`
  defp operator_config_binding(
         {:=, _,
          [
            lhs,
            {{:., _, [{:__aliases__, _, [:Application]}, fun]}, _, _args}
          ]}
       )
       when fun in @operator_config_funs do
    extract_bound_var_names(lhs)
  end

  defp operator_config_binding(_), do: []

  # The LHS of a binding may be a bare var, an `{:ok, var}` shape, a
  # `:__block__` literal-encoder wrap, or `_` for ignored binds. Pull
  # bare-var names out of all of these.
  defp extract_bound_var_names({name, _, ctx})
       when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) and name != :_,
       do: [name]

  defp extract_bound_var_names({:__block__, _, [inner]}), do: extract_bound_var_names(inner)

  defp extract_bound_var_names({:{}, _, elements}) when is_list(elements),
    do: Enum.flat_map(elements, &extract_bound_var_names/1)

  defp extract_bound_var_names({a, b}),
    do: extract_bound_var_names(a) ++ extract_bound_var_names(b)

  defp extract_bound_var_names(_), do: []

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
         _def_lines,
         op_cfg
       ) do
    classify_apply3(node, acc, file, meta, mod, fun, args, mfa, op_cfg)
  end

  # apply/3 — auto-imported Kernel form. AST shape `{:apply, _, [a,b,c]}`
  # is also produced by `def apply(a, b, c)` heads — skip those.
  defp collect({:apply, meta, [mod, fun, args]} = node, acc, file, mfa, def_lines, op_cfg) do
    case MapSet.member?(def_lines, AST.line(meta)) do
      true -> {node, acc}
      false -> classify_apply3(node, acc, file, meta, mod, fun, args, mfa, op_cfg)
    end
  end

  # apply/2 — function form. Same head-vs-call ambiguity.
  defp collect({:apply, meta, [fun, _args]} = node, acc, file, _mfa, def_lines, _op_cfg)
       when not is_nil(meta) do
    cond do
      MapSet.member?(def_lines, AST.line(meta)) -> {node, acc}
      literal_fun_ref?(fun) -> {node, acc}
      true -> {node, [diag_apply2(file, meta) | acc]}
    end
  end

  defp collect(node, acc, _file, _mfa, _def_lines, _op_cfg), do: {node, acc}

  defp classify_apply3(node, acc, file, meta, mod, fun, args, mfa, op_cfg) do
    cond do
      mfa_passthrough?(mod, fun, args, mfa) ->
        {node, acc}

      behaviour_dispatch_field?(mod) ->
        {node, acc}

      literal_module?(mod) and (literal_atom?(fun) or phoenix_action_name?(fun)) ->
        {node, acc}

      # §§ M-fb-F3 — mod is a bare var bound from Application.get_env or
      # similar in the same module → operator-config flow (Plug pattern).
      # Downgrade severity but keep the finding visible so reviewers see
      # the dispatch surface.
      not literal_module?(mod) and operator_config_var?(mod, op_cfg) ->
        {node, [diag_apply3_module_warning(file, meta) | acc]}

      not literal_module?(mod) ->
        {node, [diag_apply3_module(file, meta) | acc]}

      true ->
        {node, [diag_apply3_function(file, meta) | acc]}
    end
  end

  # Is `mod` a bare-var node whose name is in the operator-config set?
  defp operator_config_var?(mod, op_cfg) do
    case var_name(mod) do
      name when is_atom(name) -> MapSet.member?(op_cfg, name)
      _ -> false
    end
  end

  # Behaviour-dispatch field-access pattern. When the module argument
  # is `<var>.<conventional-config-field>`, the call is dispatching
  # against a configured implementation module — not user input.
  # Examples: `apply(state.module, :handle_info, [msg])` (Phoenix.
  # Endpoint, Plug.Builder, Oban.Worker), `apply(config.adapter,
  # :query, [conn])` (Ecto.Repo), `apply(opts.handler, :init, [conn])`.
  #
  # The allow-list is small and stable: `:module`, `:adapter`,
  # `:handler`, `:impl`, `:behaviour`. A field named `:value` or
  # `:user_input` is NOT exempt — only conventional behaviour-binding
  # field names trigger the carve-out.
  @behaviour_dispatch_fields [:module, :adapter, :handler, :impl, :behaviour]

  defp behaviour_dispatch_field?({{:., _, [_subject, field]}, _, []})
       when field in @behaviour_dispatch_fields,
       do: true

  defp behaviour_dispatch_field?({:__block__, _, [inner]}),
    do: behaviour_dispatch_field?(inner)

  defp behaviour_dispatch_field?(_), do: false

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

  # §§ M-fb-F3 — operator-config flow: `mod = Application.get_env(...)`
  # followed by `apply(mod, ...)`. This is the documented Plug /
  # behaviour-DI pattern (`elixir-implementing` §1 rule 31). The dispatch
  # surface is still worth surfacing in review, but it's not an RCE
  # vector — operator-controlled config can't be reached by request input.
  defp diag_apply3_module_warning(file, meta) do
    Diagnostic.warning("5.51",
      title: "apply/3 with operator-config module",
      message:
        "apply(mod, fun, args) where `mod` is bound from " <>
          "`Application.get_env/fetch_env/compile_env`. This is the canonical " <>
          "Plug / behaviour-DI pattern — module choice is operator-controlled " <>
          "config, not request input. Severity downgraded from :error to :warning " <>
          "because there's no path from external input to `mod`.",
      why:
        "The discriminator for rule 5.51 is taint: does the module variable's " <>
          "value reach from request data? Application config is loaded from " <>
          ".exs files at deploy time (or compile time for compile_env), so an " <>
          "attacker can't influence it. Plug and Ecto use this pattern " <>
          "extensively — see Plug.Parsers.JSON, Plug.RewriteOn, Plug.SSL.",
      alternatives: [
        Fix.new(
          summary: "If this is intentional behaviour-DI, document the contract",
          detail:
            "Add `@callback`s the configured module must implement, and validate " <>
              "the module at boot (e.g. in init/1). Tests then swap the impl via Mox.",
          applies_when: "The configured module is meant to satisfy a stable behaviour contract."
        ),
        Fix.new(
          summary: "If the set of modules is small, replace with a bounded registry",
          detail:
            "`@modules %{key => MyApp.RealModule}` + `Map.fetch(@modules, key)`. " <>
              "Compile-time map is auditable; unknown keys return `{:error, _}`.",
          applies_when:
            "There are 2–3 implementations chosen per environment, not many runtime choices."
        )
      ],
      tags: [:security, :plug_pattern],
      file: file,
      line: AST.line(meta)
    )
  end

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
