defmodule Archdo.Rules.Module.UnsafeDeserialization do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.50"

  @impl true
  def description,
    do: "Unsafe deserialization or runtime eval — RCE vector against untrusted input"

  @impl true
  def cleanup_pass, do: 6

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> walk_with_macro_context(file, ast)
    end
  end

  # §§ M-fb-F7 — static-source downgrade. Compute the set of line
  # numbers where `Code.eval_string/compile_string/eval_quoted` has a
  # module-local source (literal, or a bare var bound in the same
  # function from a literal / private-fn call). At those lines, the
  # diagnostic drops from :error to :warning.
  #
  # Bytes statically traceable inside the same module are not RCE —
  # an attacker can't reach them without modifying the source. Code-
  # generation tools that compile their own emitted bytes (UA Alphabet's
  # `mix_exs_emit_safe?/1`) are the canonical use case.
  defp module_local_eval_lines(ast) do
    {_, lines} =
      Macro.prewalk(ast, MapSet.new(), fn
        {kind, _, [head, [{_, body}]]} = node, acc
        when kind in [:def, :defp] and is_tuple(head) ->
          bindings = collect_local_bindings(body)
          {node, add_module_local_eval_lines(body, bindings, acc)}

        node, acc ->
          {node, acc}
      end)

    lines
  end

  # Walk the function body collecting `var = RHS` bindings into a map
  # `%{var_name => rhs_ast}`. Multi-binding (e.g. `{:ok, var} = ...`) is
  # only relevant when the RHS is a literal/private-call — for taint
  # purposes we register the var with the RHS so downstream lookup can
  # classify it.
  defp collect_local_bindings(body) do
    {_, map} =
      Macro.prewalk(body, %{}, fn
        {:=, _, [lhs, rhs]} = node, acc ->
          {node, add_bindings_from_lhs(lhs, rhs, acc)}

        node, acc ->
          {node, acc}
      end)

    map
  end

  defp add_bindings_from_lhs({name, _, ctx}, rhs, acc)
       when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) and name != :_,
       do: Map.put(acc, name, rhs)

  defp add_bindings_from_lhs({:__block__, _, [inner]}, rhs, acc),
    do: add_bindings_from_lhs(inner, rhs, acc)

  defp add_bindings_from_lhs({:{}, _, elements}, rhs, acc) when is_list(elements),
    do: Enum.reduce(elements, acc, &add_bindings_from_lhs(&1, rhs, &2))

  defp add_bindings_from_lhs({a, b}, rhs, acc),
    do: a |> add_bindings_from_lhs(rhs, acc) |> then(&add_bindings_from_lhs(b, rhs, &1))

  defp add_bindings_from_lhs(_, _, acc), do: acc

  # Walk body finding eval sites; for each, decide if its arg is
  # module-local. If yes, add the call's line to the override set.
  defp add_module_local_eval_lines(body, bindings, acc) do
    {_, lines} =
      Macro.prewalk(body, acc, fn node, inner_acc ->
        case eval_call_info(node) do
          nil ->
            {node, inner_acc}

          {meta, arg} ->
            case module_local_source?(arg, bindings) do
              true -> {node, MapSet.put(inner_acc, AST.line(meta))}
              false -> {node, inner_acc}
            end
        end
      end)

    lines
  end

  # Return `{meta, first_arg}` if node is Code.eval_string / compile_string /
  # eval_quoted, else nil. We only consider the FIRST positional argument —
  # the source string / quoted form. eval_string/2's second arg (bindings)
  # is unrelated to taint.
  defp eval_call_info({{:., _, [{:__aliases__, _, [:Code]}, fun]}, meta, [arg | _]})
       when fun in [:eval_string, :compile_string, :eval_quoted],
       do: {meta, arg}

  defp eval_call_info(_), do: nil

  # Decide if `arg` is statically traceable to module-local bytes.
  # - Direct literal binary → yes
  # - Bare variable whose binding's RHS is taint-free → yes
  # - Anything else → no
  defp module_local_source?({:__block__, _, [inner]}, bindings),
    do: module_local_source?(inner, bindings)

  defp module_local_source?(arg, _bindings) when is_binary(arg), do: true

  defp module_local_source?({name, _, ctx}, bindings)
       when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) do
    case Map.fetch(bindings, name) do
      {:ok, rhs} -> not contains_taint?(rhs)
      :error -> false
    end
  end

  defp module_local_source?(_, _), do: false

  # Taint markers — any of these in the RHS means we can't claim the
  # bytes are module-local. The list is deliberately conservative; new
  # taint sources can be added without changing the downgrade semantics
  # for already-classified shapes.
  @taint_modules [:File, :IO]
  @taint_erlang_modules [:gen_tcp, :gen_udp, :ssl, :inet]

  defp contains_taint?(ast) do
    AST.contains?(ast, &taint_node?/1)
  end

  # File.read*, IO.read/gets/binread, etc.
  defp taint_node?({{:., _, [{:__aliases__, _, [mod]}, _fun]}, _, _})
       when mod in @taint_modules,
       do: true

  # :gen_tcp.recv, :gen_udp.recv, :ssl.recv
  defp taint_node?({{:., _, [erl_mod, _fun]}, _, _})
       when erl_mod in @taint_erlang_modules,
       do: true

  # conn.params, conn.body_params, conn.req_headers — any field access
  # on a variable named `conn` is treated as request-derived.
  defp taint_node?({{:., _, [{:conn, _, ctx}, _field]}, _, _})
       when is_atom(ctx) or is_nil(ctx),
       do: true

  # `params["key"]` — bracket access on a var named `params` (Phoenix
  # convention).
  defp taint_node?({{:., _, [Access, :get]}, _, [{:params, _, ctx}, _key]})
       when is_atom(ctx) or is_nil(ctx),
       do: true

  defp taint_node?(_), do: false

  # Use Macro.traverse to track compile-time-context nesting depth. While
  # depth > 0 we're inside one of:
  #   - `defmacro` / `defmacrop` body — `Code.eval_quoted` operates on
  #     caller-supplied quoted forms at COMPILE TIME, not runtime input.
  #   - `quote do ... end` block — code emitted into a consumer module
  #     and evaluated at the consumer's compile time. DSL extension
  #     callbacks (e.g. Spark `Dsl.Section.after_define`) return a quote
  #     containing `Code.eval_quoted` that runs when the consumer is built.
  #
  # This is the established Elixir metaprogramming idiom (Ash.TypedStruct,
  # Ash.Type.Comparable, Ash.Spark extensions, every codegen library).
  # Sobelow has the same exemption via its `# sobelow_skip` annotation.
  #
  # Other detections (binary_to_term, Code.eval_string, Code.compile_string,
  # Jason :atoms) keep firing inside compile-time contexts too — those are
  # runtime threats regardless of where the call lives.
  @compile_time_kinds [:defmacro, :defmacrop, :quote]

  defp walk_with_macro_context(file, ast) do
    # §§ M-fb-F7 — pre-pass: lines where Code.eval_* args are
    # module-local. Threaded through traversal state so the eval
    # detectors below downgrade rather than emit :error.
    local_eval_lines = module_local_eval_lines(ast)

    {_, {findings, _depth}} =
      Macro.traverse(
        ast,
        {[], 0},
        # Pre: enter defmacro/defmacrop/quote → increment depth
        fn
          {kind, _, _} = node, {acc, depth} when kind in @compile_time_kinds ->
            {node, {acc, depth + 1}}

          node, state ->
            {node, state}
        end,
        # Post: leave defmacro/defmacrop/quote → decrement; check call shapes
        fn
          {kind, _, _} = node, {acc, depth} when kind in @compile_time_kinds ->
            {node, {acc, depth - 1}}

          node, {acc, depth} ->
            {node, {check_node(node, acc, file, depth, local_eval_lines), depth}}
        end
      )

    Enum.reverse(findings)
  end

  # Per-node check, dispatched by AST shape. The depth threading is
  # only consulted by the `Code.eval_quoted` clause — it's the one
  # idiom whose compile-time-vs-runtime classification depends on
  # surrounding context.
  defp check_node(node, acc, file, depth, local_eval_lines) do
    {_, new_acc} = collect(node, acc, file, depth, local_eval_lines)
    new_acc
  end

  # §§ elixir-implementing: §5.2, §7.6 — multi-clause head dispatch over `case`
  # for AST shape detection. Each clause matches one defect class.

  # :erlang.binary_to_term(_payload) — no opts means no :safe
  defp collect(
         {{:., _, [:erlang, :binary_to_term]}, meta, [_payload]} = node,
         acc,
         file,
         _depth,
         _local_lines
       ) do
    {node, [diag_binary_to_term(file, meta) | acc]}
  end

  # :erlang.binary_to_term(_payload, opts) — flag if opts list lacks :safe
  defp collect(
         {{:., _, [:erlang, :binary_to_term]}, meta, [_payload, opts]} = node,
         acc,
         file,
         _depth,
         _local_lines
       ) do
    case safe_in_opts?(opts) do
      true -> {node, acc}
      false -> {node, [diag_binary_to_term(file, meta) | acc]}
    end
  end

  # Code.eval_quoted — suppress when inside a defmacro body (depth > 0).
  # Inside a macro, eval_quoted operates on a caller-supplied quoted form
  # at COMPILE TIME — the established Elixir metaprogramming pattern.
  defp collect(
         {{:., _, [{:__aliases__, _, [:Code]}, :eval_quoted]}, meta, _args} = node,
         acc,
         file,
         depth,
         local_lines
       ) do
    cond do
      depth > 0 ->
        {node, acc}

      MapSet.member?(local_lines, AST.line(meta)) ->
        {node, [diag_code_eval_warning(file, :eval_quoted, meta) | acc]}

      true ->
        {node, [diag_code_eval(file, :eval_quoted, meta) | acc]}
    end
  end

  # Code.eval_string / Code.compile_string — runtime parse+eval of a
  # string. Even in macro context this is a real threat (a macro that
  # eval_strings a runtime arg leaks the threat to the caller). Keep
  # flagging — but downgrade to :warning when the source is module-local
  # (M-fb-F7).
  defp collect(
         {{:., _, [{:__aliases__, _, [:Code]}, fun]}, meta, _args} = node,
         acc,
         file,
         _depth,
         local_lines
       )
       when fun in [:eval_string, :compile_string] do
    case MapSet.member?(local_lines, AST.line(meta)) do
      true -> {node, [diag_code_eval_warning(file, fun, meta) | acc]}
      false -> {node, [diag_code_eval(file, fun, meta) | acc]}
    end
  end

  # Jason.decode!(json, keys: :atoms) / Jason.decode(json, keys: :atoms)
  defp collect(
         {{:., _, [{:__aliases__, _, [:Jason]}, fun]}, meta, [_json, opts]} = node,
         acc,
         file,
         _depth,
         _local_lines
       )
       when fun in [:decode, :decode!] and is_list(opts) do
    case Keyword.get(opts, :keys) do
      :atoms -> {node, [diag_jason_atoms(file, fun, meta) | acc]}
      _ -> {node, acc}
    end
  end

  defp collect(node, acc, _file, _depth, _local_lines), do: {node, acc}

  # §§ elixir-implementing: §7.4 — explicit shape-match in head. Only the
  # `:safe` atom literal counts. A computed expression is treated as unsafe
  # because we can't prove at analysis time that it expands to include `:safe`.
  defp safe_in_opts?(opts) when is_list(opts), do: Enum.member?(opts, :safe)
  defp safe_in_opts?(_), do: false

  defp diag_binary_to_term(file, meta) do
    Diagnostic.error("5.50",
      title: ":erlang.binary_to_term without :safe",
      message:
        ":erlang.binary_to_term/1,2 without the :safe option deserializes any " <>
          "term — including atoms, funs, and pids — which is an RCE vector against " <>
          "untrusted input.",
      why:
        "ETF deserialization can create unbounded atoms (atom-table exhaustion) and " <>
          "instantiate arbitrary terms. Even with :safe, prefer JSON + a typed DTO " <>
          "for external payloads. Reserve :erlang.binary_to_term for trusted, " <>
          "process-internal data.",
      alternatives: [
        Fix.new(
          summary: "Add :safe to the options list",
          detail:
            "Pass `[:safe]` (or include `:safe` in your existing opts list) so " <>
              "atoms must already exist and dangerous terms are rejected.",
          applies_when: "The payload source is partially trusted but you must use ETF."
        ),
        Fix.new(
          summary: "Replace ETF with JSON + DTO",
          detail:
            "For external payloads, use Jason.decode/2 (default keys: :strings) and " <>
              "parse the result into a typed struct via a new/1 constructor that " <>
              "returns {:ok, struct} | {:error, reason}.",
          applies_when: "The payload comes from outside this BEAM cluster."
        )
      ],
      tags: [:security, :critical],
      file: file,
      line: AST.line(meta)
    )
  end

  # §§ M-fb-F7 — module-local source: the eval'd bytes were produced
  # inside this module (direct literal, or a bare var bound from a
  # literal / private-fn call in the same function). Code-generation
  # tools that compile their own emitted source are the canonical use
  # case. Still worth a :warning so reviewers see the eval surface, but
  # not the RCE class — there's no attacker-input path to the bytes.
  defp diag_code_eval_warning(file, fun, meta) do
    Diagnostic.warning("5.50",
      title: "Code.#{fun} on module-local bytes",
      message:
        "Code.#{fun} where the source is module-local (literal string, " <>
          "or a bare var bound from a literal or private-function call in " <>
          "the same function). Severity downgraded from :error to :warning " <>
          "because the bytes are statically traceable inside this module — " <>
          "no attacker-input path. Code-generation tools that compile their " <>
          "own emitted source land here.",
      why:
        "The RCE risk of Code.#{fun} is taint: can the bytes reach from " <>
          "request input? When the source is constructed entirely from " <>
          "literals and private-fn calls in the same module, the answer is " <>
          "no — modifying the source requires committing code to the repo. " <>
          "Reviewers should still confirm the bytes are bounded (no concat " <>
          "with user input downstream), hence :warning rather than silence.",
      alternatives: [
        Fix.new(
          summary: "Move evaluation to build time",
          detail:
            "If this is a code generator emitting source for a deploy, " <>
              "evaluate via a Mix task before release rather than at runtime.",
          applies_when: "The eval'd source doesn't depend on runtime values."
        ),
        Fix.new(
          summary: "Replace with a quote-based macro",
          detail:
            "If the goal is to generate code at compile time, use a macro " <>
              "that returns a quoted form. The compiler emits the same code " <>
              "without a runtime Code.#{fun} call.",
          applies_when: "The eval target is structural code generation."
        )
      ],
      tags: [:security, :static_source],
      file: file,
      line: AST.line(meta)
    )
  end

  defp diag_code_eval(file, fun, meta) do
    Diagnostic.error("5.50",
      title: "Code.#{fun} on runtime input",
      message:
        "Code.#{fun} executes arbitrary Elixir source. If #{fun}'s argument can " <>
          "reach attacker-controlled input, this is RCE.",
      why:
        "Code.eval_string/eval_quoted/compile_string are intended for build-time " <>
          "tooling (mix tasks, code generators). They have no place in request " <>
          "handling, plugin execution, or any data path. Use a bounded registry of " <>
          "explicit functions instead.",
      alternatives: [
        Fix.new(
          summary: "Use a bounded command/plugin registry",
          detail:
            "Define `@commands %{\"name\" => &Mod.fun/n}` and dispatch via " <>
              "`Map.fetch(@commands, name)`. Unknown names return {:error, " <>
              ":unknown_command} instead of executing arbitrary code.",
          applies_when: "You need to dispatch on a string name from external input."
        ),
        Fix.new(
          summary: "Move evaluation to build time",
          detail:
            "If the input is genuinely a developer-supplied template, evaluate it " <>
              "at compile time via a macro or a Mix task that runs before deploy.",
          applies_when: "The 'eval' use is template/codegen, not runtime dispatch."
        )
      ],
      tags: [:security, :critical],
      file: file,
      line: AST.line(meta)
    )
  end

  defp diag_jason_atoms(file, fun, meta) do
    Diagnostic.error("5.50",
      title: "Jason.#{fun} with keys: :atoms",
      message:
        "Jason.#{fun}(_, keys: :atoms) creates a new atom for every JSON key. " <>
          "On untrusted input this exhausts the BEAM atom table (~1M limit) and " <>
          "crashes the node.",
      why:
        "Atoms are never garbage-collected. A single attacker-controlled JSON " <>
          "payload with random keys is enough to permanently consume atom-table " <>
          "space. Use the default (string keys) and convert known keys to atoms " <>
          "explicitly via String.to_existing_atom/1.",
      alternatives: [
        Fix.new(
          summary: "Decode with default string keys, then convert known keys explicitly",
          detail:
            "Drop the `keys: :atoms` option. Inside your DTO constructor, use " <>
              "`%{\"foo\" => v}` patterns to access known fields, or convert with " <>
              "`String.to_existing_atom/1` when the atom must already exist.",
          applies_when: "The JSON source is external (HTTP body, message broker, file)."
        ),
        Fix.new(
          summary: "Use keys: :atoms! when all atoms are known",
          detail:
            "If you control the schema and every key is a compile-time atom in " <>
              "your code, `keys: :atoms!` is bounded — it raises on unknown keys " <>
              "rather than creating new atoms.",
          applies_when: "The JSON keys are a closed set defined in your code."
        )
      ],
      tags: [:security, :critical],
      file: file,
      line: AST.line(meta)
    )
  end
end
