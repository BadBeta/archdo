defmodule Archdo.Rules.Boundary.RawMapInDomain do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.21"

  @impl true
  def description,
    do: "Domain function accepts a raw map and threads it to another module without parsing"

  # §§ elixir-planning: §6.5 — boundary/parsing concern. Web-boundary files
  # have their own validation rule (1.14 unvalidated_params); this rule
  # targets DOMAIN modules (lib/my_app/*.ex) where the raw map is being
  # threaded onward without a DTO/changeset gate.
  @web_markers [
    "_controller.ex",
    "/controllers/",
    "_channel.ex",
    "/channels/",
    "_live.ex",
    "/live/",
    "_plug.ex",
    "/plugs/"
  ]

  # Names that signal "this is the unparsed external map".
  @raw_map_arg_names [:params, :attrs, :payload, :input, :raw, :body]

  # Calls that constitute "the map IS being parsed/validated/cast" — finding
  # any of these in the function body suppresses the diagnostic.
  @parsing_call_names [
    :cast,
    :cast_assoc,
    :cast_embed,
    :change,
    :changeset,
    :validate,
    :validate_required,
    :validate_change,
    :new,
    :new!,
    :build,
    :parse
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case in_scope?(file) do
      true -> find_raw_map_threading(file, ast)
      false -> []
    end
  end

  defp in_scope?(file) do
    not AST.test_file?(file) and not web_file?(file)
  end

  defp web_file?(file) do
    Enum.any?(@web_markers, &String.contains?(file, &1))
  end

  defp find_raw_map_threading(file, ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {:def, _, [head, [do: body]]} = node, acc ->
          {node, classify_def(head, body, file, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(hits)
  end

  # `def f(arg) when guard, do: body` puts the head + guard inside :when
  defp classify_def({:when, _, [{name, meta, args} | _guards]}, body, file, acc)
       when is_atom(name) do
    classify_function(name, meta, args, body, file, acc)
  end

  defp classify_def({name, meta, args}, body, file, acc) when is_atom(name) do
    classify_function(name, meta, args, body, file, acc)
  end

  defp classify_def(_other, _body, _file, acc), do: acc

  defp classify_function(name, meta, args, body, file, acc) do
    arg_name = first_raw_map_arg(args)

    case arg_name do
      nil -> acc
      _ -> maybe_flag(name, arg_name, meta, args, body, file, acc)
    end
  end

  defp maybe_flag(name, arg_name, meta, _args, body, file, acc) do
    case parsing_call_present?(body) do
      true -> acc
      false -> maybe_flag_threaded(name, arg_name, meta, body, file, acc)
    end
  end

  defp maybe_flag_threaded(name, arg_name, meta, body, file, acc) do
    case threads_to_other_module?(body, arg_name) do
      true -> [build_diagnostic(file, meta, name, arg_name) | acc]
      false -> acc
    end
  end

  # §§ elixir-implementing: §5.2, §7.6 — multi-clause head dispatch on AST
  # shape. The "raw map arg" detection: bare variable named params/attrs/etc.,
  # or `%{} = X`, or `X` with `is_map(X)` guard.

  defp first_raw_map_arg([head | _rest]), do: classify_head(head)
  defp first_raw_map_arg(_), do: nil

  # `%{} = name` — empty-map binding pattern
  defp classify_head({:=, _, [{:%{}, _, []}, {name, _, ctx}]})
       when is_atom(name) and is_atom(ctx),
       do: name

  # `name` with `when is_map(name)` outside this clause: we see the bare var
  # in the head; the guard is on the parent. Since prewalk gives us the def
  # node with the guard wrapped, the bare-var case here is actually the one
  # that fired the guard. We don't try to verify the guard text — a bare
  # variable named params/attrs/etc. is enough signal.
  defp classify_head({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    case name in @raw_map_arg_names do
      true -> name
      false -> nil
    end
  end

  # `def f(arg) when is_map(arg)` is parsed as `{:when, _, [{name, _, _}, guard]}`
  defp classify_head({:when, _, [inner | _guards]}), do: classify_head(inner)

  defp classify_head(_), do: nil

  defp parsing_call_present?(body) do
    AST.contains?(body, fn
      {fun, _, args} when is_atom(fun) and is_list(args) ->
        fun in @parsing_call_names

      {{:., _, [_mod, fun]}, _, args} when is_atom(fun) and is_list(args) ->
        fun in @parsing_call_names

      _ ->
        false
    end)
  end

  # Is the named arg passed to a function call on another module?
  defp threads_to_other_module?(body, arg_name) do
    AST.contains?(body, fn
      {{:., _, [{:__aliases__, _, _}, _fun]}, _, call_args} when is_list(call_args) ->
        Enum.any?(call_args, &references_var?(&1, arg_name))

      _ ->
        false
    end)
  end

  defp references_var?({name, _, ctx}, target) when is_atom(name) and is_atom(ctx),
    do: name == target

  defp references_var?(_, _), do: false

  defp build_diagnostic(file, meta, fn_name, arg_name) do
    Diagnostic.warning("1.21",
      title: "Raw map threaded across boundary without parsing",
      message:
        "Function #{fn_name}/_'s argument `#{arg_name}` arrives as a raw map " <>
          "and is passed to another module without a changeset, DTO constructor, " <>
          "or validator. Untyped data leaks into business logic.",
      why:
        "Threading raw maps past the entry point spreads the validation surface " <>
          "across every consumer instead of localizing it at one parser. Bugs " <>
          "become impossible to localize: 'did this come from JSON, or did the " <>
          "caller hand-build a struct-shaped map?' Each downstream function ends " <>
          "up doing its own ad-hoc validation, or none at all.",
      alternatives: [
        Fix.new(
          summary: "Parse the map into a typed struct at the entry",
          detail:
            "Define a DTO module with `new/1` returning {:ok, struct} | {:error, _}. " <>
              "Convert at the boundary: `with {:ok, request} <- MyDTO.new(params), " <>
              "do: ...`. Downstream code only sees the typed struct.",
          applies_when: "The shape is well-known and worth a struct (request, command, event)."
        ),
        Fix.new(
          summary: "Build an Ecto changeset with cast/3",
          detail:
            "If the value is heading into Ecto, run it through a changeset that " <>
              "calls `cast(attrs, [:field1, :field2])`. Unknown keys are dropped " <>
              "and known keys are typed. The validation surface is the changeset.",
          applies_when: "The downstream call is Repo.insert/update or another Ecto operation."
        ),
        Fix.new(
          summary: "Destructure the expected keys in the function head",
          detail:
            "If the map has 1–3 known fields, pattern-match them in the head: " <>
              "`def f(%{user_id: uid, total: total})`. Unknown shapes raise a " <>
              "FunctionClauseError at the entry, not a confused failure deep in " <>
              "the call chain.",
          applies_when:
            "The map has a small, fixed set of fields and the function does not " <>
              "need to round-trip the whole map."
        )
      ],
      tags: [:boundary],
      file: file,
      line: AST.line(meta)
    )
  end
end
