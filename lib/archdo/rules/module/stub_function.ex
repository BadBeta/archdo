defmodule Archdo.Rules.Module.StubFunction do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "6.29"

  @impl true
  def description, do: "Function body is a stub or unimplemented placeholder"

  @impl true
  def analyze(file, ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> find_stubs(file, ast)
    end
  end

  defp find_stubs(file, ast) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        # def func(...), do: raise "not implemented"
        {def_type, meta, [{name, _, _args} | _]} = node, acc
        when def_type in [:def, :defp] ->
          case stub_body?(node) do
            {true, stub_type} ->
              {node, [build_diagnostic(file, meta, name, stub_type) | acc]}

            false ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(diagnostics)
  end

  defp stub_body?({def_type, _meta, [_head | body_parts]})
       when def_type in [:def, :defp] do
    body = extract_body(body_parts)
    classify_stub(body)
  end

  defp stub_body?(_), do: false

  defp extract_body([[do: body]]), do: body
  defp extract_body([_, [do: body]]), do: body
  defp extract_body(_), do: nil

  # raise "not implemented" / raise "TODO" / raise "not yet implemented"
  defp classify_stub({:raise, _, [message]}) when is_binary(message) do
    lower = String.downcase(message)

    cond do
      String.contains?(lower, "not implemented") -> {true, :raise_not_implemented}
      String.contains?(lower, "todo") -> {true, :raise_todo}
      String.contains?(lower, "not yet") -> {true, :raise_not_yet}
      String.contains?(lower, "implement") -> {true, :raise_not_implemented}
      String.contains?(lower, "stub") -> {true, :raise_stub}
      true -> false
    end
  end

  # raise RuntimeError, message: "not implemented"
  defp classify_stub({:raise, _, [_exception, message]}) when is_binary(message) do
    classify_stub({:raise, [], [message]})
  end

  # raise RuntimeError, "not implemented"
  defp classify_stub({:raise, _, [_exception, [message: msg]]}) when is_binary(msg) do
    classify_stub({:raise, [], [msg]})
  end

  # IO.warn("not implemented") / IO.puts("TODO: ...")
  defp classify_stub({{:., _, [{:__aliases__, _, [:IO]}, func]}, _, [message]})
       when func in [:warn, :puts] and is_binary(message) do
    lower = String.downcase(message)

    cond do
      String.contains?(lower, "not implemented") -> {true, :io_not_implemented}
      String.contains?(lower, "todo") -> {true, :io_todo}
      true -> false
    end
  end

  # Block body — check last expression
  defp classify_stub({:__block__, _, exprs}) when is_list(exprs) do
    case List.last(exprs) do
      nil -> false
      last -> classify_stub(last)
    end
  end

  # :not_implemented atom return
  defp classify_stub(:not_implemented), do: {true, :atom_not_implemented}
  defp classify_stub({:error, :not_implemented}), do: {true, :tuple_not_implemented}

  defp classify_stub({:{}, _, [:error, :not_implemented]}),
    do: {true, :tuple_not_implemented}

  defp classify_stub(_), do: false

  defp build_diagnostic(file, meta, func_name, stub_type) do
    line = AST.line(meta)

    type_message =
      case stub_type do
        :raise_not_implemented -> "raises \"not implemented\""
        :raise_todo -> "raises a TODO message"
        :raise_not_yet -> "raises \"not yet implemented\""
        :raise_stub -> "raises a stub message"
        :io_not_implemented -> "prints \"not implemented\" warning"
        :io_todo -> "prints a TODO warning"
        :atom_not_implemented -> "returns :not_implemented"
        :tuple_not_implemented -> "returns {:error, :not_implemented}"
      end

    Diagnostic.warning("6.29",
      title: "Stub function",
      message: "#{func_name} #{type_message} — unfinished implementation",
      why:
        "This function contains a placeholder body that will fail at runtime. " <>
          "Stub functions are useful during development but dangerous in production — " <>
          "they crash or silently misbehave when the code path is reached. " <>
          "If this code is shipping, implement the function. If it's intentionally " <>
          "unsupported, return a clear error tuple with documentation.",
      alternatives: [
        Fix.new(
          summary: "Implement the function",
          detail: "Replace the stub body with the actual implementation.",
          applies_when: "The function should be implemented."
        ),
        Fix.new(
          summary: "Return {:error, :not_supported} with @doc",
          detail:
            "If the operation is intentionally unsupported, return " <>
              "`{:error, :not_supported}` and document why in @doc.",
          applies_when:
            "The function is part of a behaviour but this implementation doesn't support it."
        ),
        Fix.new(
          summary: "Delete the function",
          detail: "If the function is not needed, remove it entirely.",
          applies_when: "The stub is a leftover from a copy-paste or scaffold."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#6.29"],
      context: %{function: to_string(func_name), stub_type: stub_type},
      file: file,
      line: line
    )
  end
end
