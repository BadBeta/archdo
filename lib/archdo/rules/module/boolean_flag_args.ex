defmodule Archdo.Rules.Module.BooleanFlagArgs do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  # Prefix-based flag detection (Elixir convention)
  @flag_prefixes ~w(is_ has_ should_ skip_ force_)
  @flag_exact ~w(enabled disabled active inactive admin debug verbose silent)

  @impl true
  def id, do: "6.6"

  @impl true
  def description, do: "Boolean flag arguments — usually two functions glued together"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_flag_args(file, ast)
    end
  end

  defp find_flag_args(file, ast) do
    fns = AST.extract_functions(ast, :public)

    Enum.flat_map(fns, fn {name, arity, meta, args, _body} ->
      flags = collect_flag_args(args)

      Enum.map(flags, fn flag ->
        Diagnostic.info("6.6",
          title: "Boolean flag argument",
          message: "#{name}/#{arity} takes a boolean-shaped argument named #{flag}",
          why:
            "A boolean flag in a function signature is almost always two functions glued together. The body " <>
              "starts with `if flag, do: foo, else: bar`, and call sites read as `do_thing(true)` — opaque to " <>
              "the reader who has to look up what `true` means. Splitting into two named functions makes the " <>
              "intent explicit at every call site and lets each function be specialized.",
          alternatives: [
            Fix.new(
              summary: "Split into two named functions",
              detail:
                "Replace `#{name}(arg, true)` with `#{name}_with_#{flag}(arg)` (or some other meaningful name) " <>
                  "and `#{name}(arg, false)` with `#{name}/#{arity - 1}`. Each call site now reads at a glance.",
              example: """
              ```elixir
              # before
              schedule(job, true)
              schedule(job, false)

              # after
              schedule_immediate(job)
              schedule_deferred(job)
              ```
              """,
              applies_when: "The two paths are meaningfully different operations."
            ),
            Fix.new(
              summary: "Replace the boolean with an enum atom",
              detail:
                "If you want to keep one function but make the call site clearer, change the boolean to a tagged " <>
                  "atom (`:async`/`:sync`, `:strict`/`:lenient`). The call sites read as English and adding a " <>
                  "third mode later doesn't break the signature.",
              applies_when: "The decision is one of several modes, not strictly two."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#6.6"],
          context: %{function: "#{name}/#{arity}", flag_arg: flag},
          file: file,
          line: AST.line(meta)
        )
      end)
    end)
  end

  defp collect_flag_args(args) when is_list(args) do
    args
    |> Enum.map(&arg_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&flag_name?/1)
  end

  defp collect_flag_args(_), do: []

  defp arg_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: Atom.to_string(name)
  defp arg_name({:\\, _, [{name, _, _} | _]}) when is_atom(name), do: Atom.to_string(name)
  defp arg_name(_), do: nil

  defp flag_name?(name) do
    Enum.any?(@flag_prefixes, &String.starts_with?(name, &1)) or
      String.ends_with?(name, "?") or
      name in @flag_exact
  end
end
