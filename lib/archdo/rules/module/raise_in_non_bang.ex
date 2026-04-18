defmodule Archdo.Rules.Module.RaiseInNonBang do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.10"

  @impl true
  def description, do: "Non-bang functions should return ok/error tuples, not raise"

  # Functions where raising is idiomatic (setup, validation, compile-time, framework callbacks)
  @raise_ok_contexts ~w(validate! assert! ensure! check! start! stop! init)a

  # Framework callbacks where raising is "let it crash" by convention
  @framework_callbacks ~w(
    handle_init handle_setup handle_playing handle_terminate
    handle_pad_added handle_pad_removed handle_child_notification
    handle_parent_notification handle_element_start_of_stream
    handle_element_end_of_stream handle_tick handle_stream_format
    handle_event handle_buffer handle_process handle_demand
    handle_info handle_call handle_cast handle_continue
    handle_set_up_tracks handle_input_tracks_negotiated
    handle_output_tracks_negotiated
    terminate code_change format_status callback_mode
  )a

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      find_raises_in_non_bang(file, ast)
    end
  end

  defp find_raises_in_non_bang(file, ast) do
    fns = AST.extract_functions(ast, :public)

    fns
    |> Enum.reject(fn {name, _arity, _meta, _args, _body} ->
      not is_atom(name) or bang_function?(name) or name in @raise_ok_contexts or
        name in @framework_callbacks
    end)
    |> Enum.filter(fn {_name, _arity, _meta, _args, body} ->
      body != nil and contains_raise?(body) and not has_rescue?(body)
    end)
    |> Enum.map(fn {name, arity, meta, _args, _body} ->
      build_diagnostic(file, name, arity, meta)
    end)
  end

  defp bang_function?(name) do
    name
    |> Atom.to_string()
    |> String.ends_with?("!")
  end

  defp contains_raise?(body) do
    AST.contains?(body, fn
      {:raise, _, _} -> true
      _ -> false
    end)
  end

  # If the function has its own rescue block, the raise is intentionally caught
  defp has_rescue?(body) do
    AST.contains?(body, fn
      {:rescue, _} -> true
      _ -> false
    end)
  end

  defp build_diagnostic(file, name, arity, meta) do
    Diagnostic.warning("6.10",
      title: "Non-bang function raises instead of returning error tuple",
      message: "#{name}/#{arity} calls `raise` but is not named with a trailing `!`",
      why:
        "Elixir convention: functions named without `!` should return `{:ok, result}` or " <>
          "`{:error, reason}`. Functions named with `!` (like `File.read!`) may raise. When a " <>
          "non-bang function raises, callers who expect ok/error tuples get an unexpected exception " <>
          "instead. This breaks `with` chains, pattern-matched pipelines, and the caller's ability " <>
          "to decide how to handle the error. The Elixir official anti-patterns guide lists this as " <>
          "'Raising exceptions for control flow.'",
      alternatives: [
        Fix.new(
          summary: "Return `{:ok, result}` / `{:error, reason}` instead of raising",
          detail:
            "Replace `raise \"message\"` with `{:error, :descriptive_atom}` or `{:error, message}`. " <>
              "If callers need both variants, keep the raising version as `#{name}!/#{arity}` " <>
              "and make the current function return tuples.",
          example: """
          ```elixir
          # Non-bang returns tuples:
          def parse(input) do
            case do_parse(input) do
              nil -> {:error, :invalid_format}
              result -> {:ok, result}
            end
          end

          # Bang raises (for callers who want it):
          def parse!(input) do
            case parse(input) do
              {:ok, result} -> result
              {:error, reason} -> raise ArgumentError, "parse failed: \#{reason}"
            end
          end
          ```
          """,
          applies_when: "The function is called by other modules that need to handle errors."
        ),
        Fix.new(
          summary: "Rename to `#{name}!` if raising is the intended behaviour",
          detail:
            "If the raise is intentional (the function is meant to crash on invalid input, like " <>
              "a validation guard), rename it with a `!` suffix so callers know what to expect.",
          applies_when: "The function is intentionally strict — callers should never pass invalid input."
        ),
        Fix.new(
          summary: "Keep the raise if this is compile-time or startup validation",
          detail:
            "Raises in module body, `@` attribute evaluation, or `init/1` for missing config are " <>
              "idiomatic — they fail fast at boot, not at runtime. If the raise only fires during " <>
              "compilation or application start, it's fine.",
          applies_when: "The raise is a compile-time or startup guard, not a runtime error path."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.10"],
      context: %{function: "#{name}/#{arity}"},
      file: file,
      line: AST.line(meta)
    )
  end
end
