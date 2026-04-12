defmodule Archdo.Rules.OTP.ScatteredGenserverCall do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "5.17"

  @impl true
  def description, do: "GenServer.call/cast should only be used in the defining module"

  @impl true
  def analyze(file, ast, _opts) do
    if AST.test_file?(file) do
      []
    else
      defining_module = extract_module_name(ast)
      find_scattered_calls(file, ast, defining_module)
    end
  end

  defp find_scattered_calls(file, ast, defining_module) do
    AST.find_all(ast, fn
      # GenServer.call(LiteralModule, msg) or GenServer.call(LiteralModule, msg, timeout)
      {{:., _, [{:__aliases__, _, [:GenServer]}, call_type]}, _meta, [{:__aliases__, _, _target} | _]}
      when call_type in [:call, :cast] ->
        true

      # Agent.get/update/get_and_update with literal name
      {{:., _, [{:__aliases__, _, [:Agent]}, func]}, _meta, [{:__aliases__, _, _target} | _]}
      when func in [:get, :update, :get_and_update] ->
        true

      _ ->
        false
    end)
    |> Enum.filter(fn
      {{:., _, [{:__aliases__, _, [:GenServer]}, _]}, _, [{:__aliases__, _, target} | _]} ->
        Module.concat(target) != defining_module

      {{:., _, [{:__aliases__, _, [:Agent]}, _]}, _, [{:__aliases__, _, target} | _]} ->
        Module.concat(target) != defining_module
    end)
    |> Enum.map(fn
      {{:., _, [{:__aliases__, _, [caller_mod]}, func]}, meta, [{:__aliases__, _, target} | _]} ->
        target_name = Enum.join(target, ".")
        call = "#{caller_mod}.#{func}"

        Diagnostic.warning("5.17",
          title: "Scattered process interface",
          message: "#{call}(#{target_name}, ...) is called from outside #{target_name}",
          why:
            "Direct GenServer.call/cast and Agent.get/update with literal module names couple every caller to " <>
              "the receiver's message protocol. Any change to the message tuple, timeout, or argument order " <>
              "requires updating every call site. The defining module should expose a public API function that " <>
              "wraps the call so the protocol stays internal — Elixir's official anti-pattern catalogue lists " <>
              "this as 'Scattered Process Interfaces'.",
          alternatives: [
            Fix.new(
              summary: "Add a public function to #{target_name} that wraps the call",
              detail:
                "Define a public function inside #{target_name} (e.g. `def do_thing(args), do: GenServer.call(__MODULE__, " <>
                  "{:do_thing, args})`) and replace every external call site with that function. Now the protocol " <>
                  "is private to the module and can change without ripple-edits.",
              example: """
              ```elixir
              # in #{target_name}:
              def do_thing(args), do: GenServer.call(__MODULE__, {:do_thing, args})

              # at call sites:
              #{target_name}.do_thing(args)
              ```
              """,
              applies_when: "The call site is in non-test production code."
            )
          ],
          references: ["ARCHITECTURE_RULES.md#5.17"],
          context: %{call: call, target: target_name},
          file: file,
          line: AST.line(meta)
        )
    end)
  end

  defp extract_module_name(ast) do
    {_, name} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, aliases} | _]} = node, nil ->
          {node, Module.concat(aliases)}

        node, acc ->
          {node, acc}
      end)

    name
  end

end
