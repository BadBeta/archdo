defmodule Archdo.Rules.Module.TimeInjection do
  @moduledoc false
  @behaviour Archdo.Rule

  # §§ elixir-planning: §6 — operational layer carve-out via Archdo.Phoenix.
  # Mix tasks run once; injecting a clock for testability is unnecessary.

  alias Archdo.{AST, Diagnostic, Fix, Phoenix}

  @time_calls [
    {[:DateTime], :utc_now},
    {[:Date], :utc_today},
    {[:NaiveDateTime], :utc_now},
    {[:Time], :utc_now},
    {[:System], :system_time},
    {[:System], :monotonic_time},
    {[:System], :os_time},
    {[:Calendar], :universal_time}
  ]

  @impl true
  def id, do: "1.9"

  @impl true
  def description, do: "Time/date should be injectable for testability"

  @impl true
  def analyze(file, ast, opts) do
    classification =
      case Keyword.get(opts, :phoenix) do
        %{layer: _} = c -> c
        _ -> Phoenix.classify_file(file, ast)
      end

    case AST.test_file?(file) or infrastructure_file?(file) or
           Phoenix.operational?(classification) do
      true -> []
      false -> find_uninjected_time(file, ast)
    end
  end

  defp find_uninjected_time(file, ast) do
    # §§ elixir-implementing: §5.2 — collect default-arg call lines
    # FIRST so we can exclude them from the diagnostic set. A
    # `def f(now \\ DateTime.utc_now())` IS the rule's recommended
    # injection mechanism — flagging it defeats the suggested fix.
    default_arg_lines = collect_default_arg_time_lines(ast)

    AST.find_all(ast, fn
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, _meta, _args} ->
        Enum.any?(@time_calls, fn {mod, fname} -> mod_parts == mod and func == fname end)

      _ ->
        false
    end)
    |> Enum.reject(fn {_, meta, _} -> AST.line(meta) in default_arg_lines end)
    |> Enum.uniq_by(fn {{:., _, [{:__aliases__, _, mod}, func]}, _, _} -> {mod, func} end)
    |> Enum.map(fn {{:., _, [{:__aliases__, _, mod}, func]}, meta, _} ->
      call = "#{Enum.join(mod, ".")}.#{func}"

      Diagnostic.info("1.9",
        title: "Hard-coded clock dependency",
        message: "Direct call to #{call} — current time is not injected",
        why:
          "Reading the wall clock directly makes the code untestable: tests can't pin time, can't simulate " <>
            "time-dependent edge cases (timezones, midnight rollovers, scheduled jobs), and can't make " <>
            "assertions about durations without flakiness. Domain code that depends on now should accept the " <>
            "clock from outside so tests can swap in a known value.",
        alternatives: [
          Fix.new(
            summary: "Accept the current time as a function argument",
            detail:
              "Add a `now \\\\ DateTime.utc_now()` argument (or similar) to the public function. Production " <>
                "calls use the default; tests pass an explicit timestamp. Zero ceremony, zero global state.",
            example: """
            ```elixir
            def schedule(event, now \\\\ DateTime.utc_now()) do
              # use `now` instead of DateTime.utc_now()
            end
            ```
            """,
            applies_when: "The function is small enough that adding an argument is reasonable."
          ),
          Fix.new(
            summary: "Inject a clock module via Application config",
            detail:
              "Define a `Clock` behaviour with `now/0`, default to a `RealClock` module that calls " <>
                "DateTime.utc_now/0, and read the implementation via `Application.get_env(:my_app, :clock, RealClock)`. " <>
                "Tests configure a `FakeClock` that returns a fixed time.",
            applies_when:
              "Many functions in the module need the clock and an argument is too noisy."
          )
        ],
        references: ["ARCHITECTURE_RULES.md#1.9"],
        context: %{call: call},
        file: file,
        line: AST.line(meta)
      )
    end)
  end

  # Walk every def/defp head and collect line numbers of time calls
  # that appear inside `arg \\ <default_expr>` patterns. Those lines
  # are the function-default-arg sites and represent the injection
  # mechanism itself, not a hardcoded body call.
  defp collect_default_arg_time_lines(ast) do
    {_, lines} =
      Macro.prewalk(ast, [], fn
        {def_kind, _meta, [{_name, _, args} | _]} = node, acc
        when def_kind in [:def, :defp] and is_list(args) ->
          new_lines = args |> Enum.flat_map(&time_lines_in_default/1)
          {node, new_lines ++ acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.new(lines)
  end

  defp time_lines_in_default({:\\, _, [_pattern, default_expr]}) do
    AST.find_all(default_expr, fn
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, _meta, _args} ->
        Enum.any?(@time_calls, fn {mod, fname} -> mod_parts == mod and func == fname end)

      _ ->
        false
    end)
    |> Enum.map(fn {_, meta, _} -> AST.line(meta) end)
  end

  defp time_lines_in_default(_), do: []

  defp infrastructure_file?(file) do
    String.contains?(file, "/infrastructure/") or
      String.contains?(file, "/adapter") or
      String.ends_with?(file, "/application.ex") or
      String.contains?(file, "/clock") or
      String.contains?(file, "/time")
  end
end
