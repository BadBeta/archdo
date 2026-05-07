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
            {node, {check_node(node, acc, file, depth), depth}}
        end
      )

    Enum.reverse(findings)
  end

  # Per-node check, dispatched by AST shape. The depth threading is
  # only consulted by the `Code.eval_quoted` clause — it's the one
  # idiom whose compile-time-vs-runtime classification depends on
  # surrounding context.
  defp check_node(node, acc, file, depth) do
    {_, new_acc} = collect(node, acc, file, depth)
    new_acc
  end

  # §§ elixir-implementing: §5.2, §7.6 — multi-clause head dispatch over `case`
  # for AST shape detection. Each clause matches one defect class.

  # :erlang.binary_to_term(_payload) — no opts means no :safe
  defp collect(
         {{:., _, [:erlang, :binary_to_term]}, meta, [_payload]} = node,
         acc,
         file,
         _depth
       ) do
    {node, [diag_binary_to_term(file, meta) | acc]}
  end

  # :erlang.binary_to_term(_payload, opts) — flag if opts list lacks :safe
  defp collect(
         {{:., _, [:erlang, :binary_to_term]}, meta, [_payload, opts]} = node,
         acc,
         file,
         _depth
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
         depth
       ) do
    case depth > 0 do
      true -> {node, acc}
      false -> {node, [diag_code_eval(file, :eval_quoted, meta) | acc]}
    end
  end

  # Code.eval_string / Code.compile_string — runtime parse+eval of a
  # string. Even in macro context this is a real threat (a macro that
  # eval_strings a runtime arg leaks the threat to the caller). Keep
  # flagging.
  defp collect(
         {{:., _, [{:__aliases__, _, [:Code]}, fun]}, meta, _args} = node,
         acc,
         file,
         _depth
       )
       when fun in [:eval_string, :compile_string] do
    {node, [diag_code_eval(file, fun, meta) | acc]}
  end

  # Jason.decode!(json, keys: :atoms) / Jason.decode(json, keys: :atoms)
  defp collect(
         {{:., _, [{:__aliases__, _, [:Jason]}, fun]}, meta, [_json, opts]} = node,
         acc,
         file,
         _depth
       )
       when fun in [:decode, :decode!] and is_list(opts) do
    case Keyword.get(opts, :keys) do
      :atoms -> {node, [diag_jason_atoms(file, fun, meta) | acc]}
      _ -> {node, acc}
    end
  end

  defp collect(node, acc, _file, _depth), do: {node, acc}

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
