defmodule Archdo.Rules.Module.DeadPrivateFunction do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # File.exists? + File.read for HEEx templates IS the boundary work —
  # this rule looks at template files to find function references via
  # `<.fn_name>` syntax that AST analysis can't see. The file content
  # IS the input; no substitutability hole.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  @impl true
  def id, do: "6.34"

  @impl true
  def description, do: "Private function is never called within its module"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_dead_privates(file, ast)
    end
  end

  defp find_dead_privates(file, ast) do
    private_fns = AST.extract_functions(ast, :private)
    private_defs = unique_private_defs(private_fns)
    call_set = collect_calls(file, ast)

    for {name, arity} = fn_def <- private_defs,
        # Direct call matches arity exactly.
        # Pipe call has arity - 1 (the pipe provides the first argument).
        not skip_function?(fn_def),
        not MapSet.member?(call_set, {name, arity}),
        arity == 0 or not MapSet.member?(call_set, {name, arity - 1}) do
      meta = find_meta(private_fns, name, arity)
      build_diagnostic(file, AST.line(meta), name, arity)
    end
  end

  defp unique_private_defs(private_fns) do
    private_fns
    |> Enum.map(fn {name, arity, _meta, _args, _body} -> {name, arity} end)
    |> Enum.uniq()
  end

  defp find_meta(private_fns, name, arity) do
    case Enum.find(private_fns, fn {n, a, _m, _args, _body} -> n == name and a == arity end) do
      {_, _, meta, _, _} -> meta
      nil -> []
    end
  end

  defp skip_function?({:when, _arity}), do: true

  defp skip_function?({name, _arity}) do
    name_str = Atom.to_string(name)

    (String.starts_with?(name_str, "__") and String.ends_with?(name_str, "__")) or
      String.starts_with?(name_str, "sigil_")
  end

  # Collect all function calls from function bodies and HEEx templates.
  defp collect_calls(file, ast) do
    all_fns = AST.extract_functions(ast, :all)
    # Also scan macro bodies — `defmacro` / `defmacrop` can call private
    # functions defined in the same module. Without this, helpers used only
    # from a macro body look dead. (Found 2026-04-29 on phoenix_live_dashboard:
    # `expand_alias/2` called from `defmacro live_dashboard`.)
    macro_bodies = extract_macro_bodies(ast)

    body_calls =
      Enum.reduce(all_fns ++ macro_bodies, MapSet.new(), fn {_n, _a, _m, _args, body}, acc ->
        collect_calls_in_body(body, acc)
      end)

    # Also scan ~H sigils for function references (Phoenix HEEx templates)
    heex_calls = collect_heex_calls(ast)

    # And follow `embed_templates "<glob>"` to scan external .heex/.eex files
    # (Phoenix idiom — function components or layouts compiled from disk).
    embedded_calls = collect_embed_template_calls(file, ast)

    body_calls
    |> MapSet.union(heex_calls)
    |> MapSet.union(embedded_calls)
  end

  # Phoenix's `embed_templates "<glob>"` compiles separate template files into
  # the module. Functions defined in the embedding module (often `defp`) are
  # called from those templates — we must scan them as additional call sites.
  # BUG-7 from phoenix_live_dashboard.
  defp collect_embed_template_calls(file, ast) do
    case is_binary(file) and File.exists?(file) do
      false ->
        MapSet.new()

      true ->
        module_dir = Path.dirname(file)

        ast
        |> find_embed_template_globs()
        |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(module_dir, glob)) end)
        |> Enum.filter(&template_file?/1)
        |> Enum.reduce(MapSet.new(), &absorb_template_refs/2)
    end
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the File.read result tag.
  defp absorb_template_refs(template_path, acc) do
    union_refs(File.read(template_path), acc)
  end

  defp union_refs({:ok, text}, acc), do: MapSet.union(acc, extract_function_refs_from_heex(text))
  defp union_refs({:error, _}, acc), do: acc

  defp find_embed_template_globs(ast) do
    {_, globs} =
      Macro.prewalk(ast, [], fn
        # `embed_templates "path/*"` — bare string (no encoder)
        {:embed_templates, _, [glob]} = node, acc when is_binary(glob) ->
          {node, [glob | acc]}

        # `embed_templates "path/*"` — literal_encoder-wrapped string
        {:embed_templates, _, [{:__block__, _, [glob]}]} = node, acc when is_binary(glob) ->
          {node, [glob | acc]}

        node, acc ->
          {node, acc}
      end)

    globs
  end

  defp template_file?(path) do
    String.ends_with?(path, ".heex") or String.ends_with?(path, ".eex")
  end

  # Extract macro bodies in the same shape as AST.extract_functions returns.
  defp extract_macro_bodies(ast) do
    {_, macros} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [{:when, _, [{name, _, args} | _]}, body]} = node, acc
        when kind in [:defmacro, :defmacrop] and is_atom(name) and is_list(args) ->
          {node, [{name, length(args), meta, args, body} | acc]}

        {kind, meta, [{name, _, args}, body]} = node, acc
        when kind in [:defmacro, :defmacrop] and is_atom(name) and is_list(args) ->
          {node, [{name, length(args), meta, args, body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(macros)
  end

  # Scan ~H"""...""" sigil bodies for function name references.
  # HEEx templates call private functions like `polyline(@points, ...)` or
  # `format_uptime()` which appear as bare text inside the template string.
  defp collect_heex_calls(ast) do
    {_, calls} =
      Macro.prewalk(ast, MapSet.new(), fn
        # ~H sigil: {:sigil_H, _, [{:<<>>, _, [string]}, []]}
        {:sigil_H, _, [{:<<>>, _, parts}, _]} = node, acc ->
          text = extract_sigil_text(parts)
          refs = extract_function_refs_from_heex(text)
          {node, MapSet.union(acc, refs)}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp extract_sigil_text(parts) do
    Enum.map_join(parts, fn
      s when is_binary(s) -> s
      {:__block__, _, [s]} when is_binary(s) -> s
      _ -> ""
    end)
  end

  # Find function-call-like patterns in HEEx text:
  #   - `name(`   — function-call form
  #   - `<.name`  — Phoenix function-component tag form (`<.foo />`,
  #     `<.foo class="x">`, `<.foo attr={value}>...</.foo>`). Without this,
  #     every private LiveView function component looks dead, since the
  #     parens-form check never matches a tag invocation.
  #   - `&name/N` — Elixir function capture inside `{...}` interpolations
  #     (e.g. `<.live_table row_fetcher={&fetch_applications/2}>`).
  defp extract_function_refs_from_heex(text) do
    paren_calls = Regex.scan(~r/\b([a-z_][a-z0-9_]*[!?]?)\s*\(/, text)
    tag_calls = Regex.scan(~r/<\.([a-z_][a-z0-9_]*[!?]?)\b/, text)
    capture_calls = Regex.scan(~r/&([a-z_][a-z0-9_]*[!?]?)\/\d+/, text)

    Enum.reduce(paren_calls ++ tag_calls ++ capture_calls, MapSet.new(), &absorb_match/2)
  end

  # §§ elixir-implementing: §2.1 — multi-clause head dispatching on
  # the regex-match shape ([_, name] vs other) and the
  # try_existing_atom result tag.
  defp absorb_match([_, name], acc) do
    # Only consider references to atoms that already exist — i.e. names
    # the BEAM has already seen as function names elsewhere. Unknown
    # names can't refer to a private function we're checking, so dropping
    # them is correct AND avoids atom-table exhaustion on adversarial
    # source (skill: §7.7).
    absorb_atom(AST.try_existing_atom(name), acc)
  end

  defp absorb_match(_other, acc), do: acc

  defp absorb_atom(:error, acc), do: acc

  defp absorb_atom({:ok, atom}, acc) do
    Enum.reduce(0..6, acc, fn arity, set -> MapSet.put(set, {atom, arity}) end)
  end

  defp collect_calls_in_body(body, acc) do
    {_, calls} =
      Macro.prewalk(body, acc, fn
        # Function capture: &foo/N => {:&, _, [{:/, _, [{:foo, _, _}, N]}]}
        {:&, _, [{:/, _, [{name, _, _}, arity]}]} = node, call_acc
        when is_atom(name) and is_integer(arity) ->
          {node, MapSet.put(call_acc, {name, arity})}

        # Function capture with literal_encoder: &foo/N where N is wrapped
        {:&, _, [{:/, _, [{name, _, _}, {:__block__, _, [arity]}]}]} = node, call_acc
        when is_atom(name) and is_integer(arity) ->
          {node, MapSet.put(call_acc, {name, arity})}

        # Bare function call: foo(a, b) => {:foo, meta, [a, b]}
        {name, _meta, args} = node, call_acc when is_atom(name) and is_list(args) ->
          case keyword_or_special?(name) do
            true -> {node, call_acc}
            false -> {node, MapSet.put(call_acc, {name, length(args)})}
          end

        node, call_acc ->
          {node, call_acc}
      end)

    calls
  end

  @keywords ~w[
    def defp defmodule defmacro defmacrop defguard defguardp defstruct
    defexception defprotocol defimpl defdelegate defoverridable
    alias import require use quote unquote __block__ __aliases__
    fn for with case cond if unless try receive raise throw super when and or not
    __MODULE__ __ENV__ __DIR__ __CALLER__ __STACKTRACE__
  ]a

  defp keyword_or_special?(name), do: name in @keywords

  defp build_diagnostic(file, line, name, arity) do
    Diagnostic.warning("6.34",
      title: "Dead private function",
      message: "#{name}/#{arity} is defined but never called within this module",
      why:
        "A private function that is never called is dead code. It adds cognitive " <>
          "load, increases module size, and may mask a missing call (typo or " <>
          "refactoring leftover). If the function is needed, ensure it's called; " <>
          "if not, remove it.",
      alternatives: [
        Fix.new(
          summary: "Remove the dead function",
          detail: "Delete #{name}/#{arity} and any related private helpers it calls.",
          applies_when: "The function is a leftover from a previous refactoring."
        ),
        Fix.new(
          summary: "Call the function where intended",
          detail: "If this function should be called, add the missing call site.",
          applies_when: "A call was accidentally removed or never added."
        )
      ],
      file: file,
      line: line
    )
  end
end
