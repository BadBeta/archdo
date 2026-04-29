defmodule Archdo.Rules.Boundary.SeamIntegrity do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "4.17"

  @impl true
  def description,
    do: "Calls to behaviour/protocol implementations must go through the seam, not directly"

  @impl true
  def analyze(_file, _ast, _opts), do: []

  @doc """
  Project-level: build a seam registry from all file ASTs, then detect direct
  calls to implementation modules that bypass the behaviour/protocol seam.
  """
  def analyze_project(file_asts) do
    registry = build_seam_registry(file_asts)

    protected =
      MapSet.new(Map.keys(registry.impl_to_behaviour) ++ Map.keys(registry.impl_to_protocol))

    case MapSet.size(protected) do
      0 ->
        []

      _ ->
        for {file, ast} <- file_asts,
            not excluded_file?(file),
            caller = AST.extract_module_name(ast),
            diag <- find_bypasses(file, ast, caller, protected, registry),
            do: diag
    end
  end

  # --- Phase 1: Build the seam registry ---

  defp build_seam_registry(file_asts) do
    {behaviours, impl_to_behaviour, protocols, impl_to_protocol} =
      Enum.reduce(file_asts, {%{}, %{}, %{}, %{}}, fn {file, ast}, acc ->
        acc
        |> index_behaviour_def(file, ast)
        |> index_behaviour_impls(file, ast)
        |> index_protocol_def(file, ast)
        |> index_protocol_impls(file, ast)
      end)

    %{
      behaviours: behaviours,
      protocols: protocols,
      impl_to_behaviour: impl_to_behaviour,
      impl_to_protocol: impl_to_protocol
    }
  end

  defp index_behaviour_def({behaviours, itb, protocols, itp}, file, ast) do
    has_callback? = AST.contains?(ast, &match?({:@, _, [{:callback, _, _}]}, &1))

    case has_callback? do
      true ->
        name = AST.extract_module_name(ast)
        {Map.put(behaviours, name, %{file: file}), itb, protocols, itp}

      false ->
        {behaviours, itb, protocols, itp}
    end
  end

  defp index_behaviour_impls({behaviours, itb, protocols, itp}, _file, ast) do
    module_name = AST.extract_module_name(ast)

    behaviour_refs =
      AST.find_all(ast, fn
        {:@, _, [{:behaviour, _, _}]} -> true
        _ -> false
      end)

    new_itb =
      Enum.reduce(behaviour_refs, itb, fn
        {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]}, acc ->
          bhv_name = join_module(parts)
          Map.update(acc, module_name, [bhv_name], &[bhv_name | &1])

        {:@, _, [{:behaviour, _, [atom_bhv]}]}, acc when is_atom(atom_bhv) ->
          bhv_name = AST.module_name(atom_bhv)
          Map.update(acc, module_name, [bhv_name], &[bhv_name | &1])

        _, acc ->
          acc
      end)

    {behaviours, new_itb, protocols, itp}
  end

  defp index_protocol_def({behaviours, itb, protocols, itp}, file, ast) do
    has_protocol? = AST.contains?(ast, &match?({:defprotocol, _, _}, &1))

    case has_protocol? do
      true ->
        name = AST.extract_module_name(ast)
        {behaviours, itb, Map.put(protocols, name, %{file: file}), itp}

      false ->
        {behaviours, itb, protocols, itp}
    end
  end

  defp index_protocol_impls({behaviours, itb, protocols, itp}, _file, ast) do
    impls =
      AST.find_all(ast, fn
        {:defimpl, _, _} -> true
        _ -> false
      end)

    new_itp =
      Enum.reduce(impls, itp, fn
        {:defimpl, _, [{:__aliases__, _, proto_parts}, [for: {:__aliases__, _, for_parts}] | _]},
        acc ->
          proto_name = join_module(proto_parts)
          for_name = join_module(for_parts)
          # defimpl Proto, for: Type creates module Proto.Type
          impl_module = "#{proto_name}.#{for_name}"
          Map.update(acc, impl_module, [proto_name], &[proto_name | &1])

        _, acc ->
          acc
      end)

    {behaviours, itb, protocols, new_itp}
  end

  # --- Phase 2: Detect bypasses ---

  defp find_bypasses(file, ast, caller, protected, registry) do
    calls =
      AST.find_all(ast, fn
        # Skip multi-alias syntax: alias Foo.{Bar, Baz} produces func = :{}
        {{:., _, [{:__aliases__, _, parts}, func]}, _, _}
        when is_atom(hd(parts)) and func != :{} ->
          Enum.all?(parts, &is_atom/1)

        _ ->
          false
      end)

    for {{:., _, [{:__aliases__, _, parts}, func]}, meta, args} <- calls,
        target = join_module(parts),
        MapSet.member?(protected, target),
        not type_accessor?(func, args),
        not legitimate?(caller, target, registry) do
      seams =
        Map.get(registry.impl_to_behaviour, target, []) ++
          Map.get(registry.impl_to_protocol, target, [])

      seam = List.first(seams, "unknown")
      is_behaviour = Map.has_key?(registry.impl_to_behaviour, target)
      bypass_diagnostic(file, AST.line(meta), caller, target, func, seam, is_behaviour)
    end
  end

  # `Module.t()` is the canonical Dialyzer type accessor — it returns the
  # `@type t :: ...` definition at compile time, NOT a runtime call into the
  # implementation. Skip it. Same applies to typespec-only functions like
  # `Module.t/0` reachable from `@spec encode(MyImpl.t()) :: ...`.
  # BUG-12 from otel: `Otel.OTLP.Encoder` was flagged for calling
  # `Otel.SDK.Trace.Span.t()` even though it's just a type reference.
  defp type_accessor?(:t, args) when args == [] or is_nil(args), do: true
  defp type_accessor?(_, _), do: false

  # --- Phase 3: Filter legitimate calls ---

  defp legitimate?(caller, target, registry) do
    same_namespace?(caller, target) or
      behaviour_or_protocol_def?(caller, registry) or
      supervisor_or_app?(caller) or
      sibling_implementation?(caller, target, registry)
  end

  defp same_namespace?(caller, target) do
    target_parent =
      target
      |> String.split(".")
      |> Enum.drop(-1)
      |> Enum.join(".")

    target_parent != "" and
      (caller == target_parent or String.starts_with?(caller, target_parent <> "."))
  end

  defp behaviour_or_protocol_def?(caller, registry) do
    Map.has_key?(registry.behaviours, caller) or
      Map.has_key?(registry.protocols, caller)
  end

  defp supervisor_or_app?(mod) do
    String.ends_with?(mod, "Supervisor") or
      String.ends_with?(mod, "Application")
  end

  defp sibling_implementation?(caller, target, registry) do
    caller_behaviours = Map.get(registry.impl_to_behaviour, caller, [])
    target_behaviours = Map.get(registry.impl_to_behaviour, target, [])
    Enum.any?(caller_behaviours, &(&1 in target_behaviours))
  end

  defp excluded_file?(file) do
    String.contains?(file, "/test/") or
      String.starts_with?(file, "test/") or
      String.contains?(file, "/config/") or
      String.ends_with?(file, "mix.exs") or
      String.contains?(file, "/mix/") or
      String.contains?(file, "/release")
  end

  # --- Phase 4: Diagnostics ---

  defp bypass_diagnostic(file, line, caller, target, func, seam, is_behaviour?) do
    seam_kind = if is_behaviour?, do: "@behaviour", else: "protocol"

    Diagnostic.warning("4.17",
      title: "Direct call bypasses #{seam_kind} seam",
      message:
        "#{caller} calls #{target}.#{func}() directly — " <>
          "#{target} implements #{seam_kind} #{seam} — " <>
          "use the seam via injection instead",
      why:
        "When a module calls a behaviour/protocol implementation directly instead of going " <>
          "through the seam (via Application.compile_env, function argument, or protocol " <>
          "dispatch), it hard-codes the implementation choice. Tests cannot swap it with Mox, " <>
          "and replacing the implementation later requires finding every direct call site. " <>
          "The whole point of the seam is that callers don't know which implementation they're using.",
      alternatives: [
        Fix.new(
          summary: "Inject via Application.compile_env and call through module attribute",
          detail:
            "Add `@impl_module Application.compile_env!(:my_app, :#{key_name(seam)})` " <>
              "to #{caller} and call `@impl_module.#{func}(...)` instead of `#{target}.#{func}(...)`. " <>
              "Configure the real implementation in config/runtime.exs and a mock in config/test.exs.",
          applies_when: "The implementation should be swappable per environment."
        ),
        Fix.new(
          summary: "Pass the implementation as a function argument",
          detail:
            "Accept the module as a parameter: `def my_func(#{key_name(seam)} \\\\ #{target}, ...)`. " <>
              "Tests pass a mock explicitly. This avoids global config and makes the dependency visible.",
          applies_when:
            "Only a few call sites need the seam — function-level injection is simpler."
        ),
        Fix.new(
          summary: "Call through the behaviour/protocol module instead",
          detail:
            "If #{seam} has a public API that delegates to the implementation, call " <>
              "`#{seam}.#{func}(...)` instead. The seam module handles implementation selection.",
          applies_when: "#{seam} is a facade module with its own public functions."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.17"],
      context: %{caller: caller, target: target, seam: seam, kind: seam_kind},
      file: file,
      line: line
    )
  end

  defp join_module(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  defp key_name(seam) do
    seam
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end
end
