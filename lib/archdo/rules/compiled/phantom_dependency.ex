defmodule Archdo.Rules.Compiled.PhantomDependency do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}
  alias Archdo.Compiled

  @impl true
  def id, do: "4.26"

  @impl true
  def description, do: "Module references another module but never calls any of its functions"

  @spec analyze_compiled(Compiled.t()) :: [Diagnostic.t()]
  def analyze_compiled(graph) do
    case Compiled.beam_dir(graph) do
      beam_dir when is_binary(beam_dir) -> scan_beam_dir(graph, beam_dir)
      _ -> []
    end
  end

  defp scan_beam_dir(graph, beam_dir) do
    modules = Compiled.modules(graph)
    calls_by_module = Compiled.calls_by_module(graph)
    project_modules = MapSet.new(Map.keys(modules))

    # For each beam file, extract ALL module atoms referenced in the abstract code
    # (struct expansions, remote references in patterns, type annotations, etc.)
    # Then compare against modules that actually have function calls.
    beam_dir
    |> Path.join("Elixir.*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(&phantoms_for_beam(&1, project_modules, calls_by_module))
  end

  defp phantoms_for_beam(beam_path, project_modules, calls_by_module) do
    case :beam_lib.chunks(to_charlist(beam_path), [:abstract_code]) do
      {:ok, {caller_mod, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
        phantoms_for_caller(
          MapSet.member?(project_modules, caller_mod),
          caller_mod,
          forms,
          calls_by_module,
          project_modules
        )

      _ ->
        []
    end
  end

  # §§ elixir-implementing: §2.1 — boolean → multi-clause head
  defp phantoms_for_caller(false, _caller, _forms, _calls, _projects), do: []

  defp phantoms_for_caller(true, caller_mod, forms, calls_by_module, project_modules) do
    find_phantoms(caller_mod, forms, calls_by_module, project_modules)
  end

  defp find_phantoms(caller_mod, forms, calls_by_module, project_modules) do
    # Collect all Elixir module atoms referenced anywhere in the abstract code
    referenced_modules =
      forms
      |> collect_module_refs()
      |> Enum.filter(&MapSet.member?(project_modules, &1))
      |> Enum.reject(&(&1 == caller_mod))
      |> MapSet.new()

    # Collect modules that are actually called (have remote function calls)
    actually_called =
      calls_by_module
      |> Map.get(caller_mod, [])
      |> Enum.map(fn call -> elem(call.callee, 0) end)
      |> Enum.filter(&MapSet.member?(project_modules, &1))
      |> MapSet.new()

    # Phantom = referenced but never called
    phantoms = MapSet.difference(referenced_modules, actually_called)

    phantoms
    |> Enum.map(fn target_mod ->
      ref_type = classify_reference(caller_mod, target_mod, forms)
      {target_mod, ref_type}
    end)
    # @behaviour declarations are inherently compile-time contracts — not phantom
    |> Enum.reject(fn {_mod, ref_type} -> ref_type == :behaviour end)
    |> Enum.map(fn {target_mod, ref_type} ->
      build_diagnostic(caller_mod, target_mod, ref_type)
    end)
  end

  # Walk all forms collecting Elixir module atoms
  defp collect_module_refs(forms) do
    forms
    |> Enum.flat_map(&collect_refs_from_form/1)
    |> Enum.uniq()
  end

  defp collect_refs_from_form(form) when is_tuple(form) do
    case form do
      # Attribute with module value: @behaviour SomeModule, @impl SomeModule
      {:attribute, _, _name, value} when is_atom(value) ->
        elixir_module_refs([value])

      {:attribute, _, _name, values} when is_list(values) ->
        values
        |> List.flatten()
        |> Enum.filter(&is_atom/1)
        |> elixir_module_refs()

      # Remote call: Module.function(args) — skip these, they're real calls
      {:call, _, {:remote, _, {:atom, _, _mod}, {:atom, _, _func}}, _args} ->
        []

      # Atom literal in patterns, types, etc.
      {:atom, _, value} when is_atom(value) ->
        elixir_module_refs([value])

      # Walk all tuple elements
      _ ->
        form
        |> Tuple.to_list()
        |> Enum.flat_map(&collect_refs_from_form/1)
    end
  end

  defp collect_refs_from_form(form) when is_list(form) do
    Enum.flat_map(form, &collect_refs_from_form/1)
  end

  defp collect_refs_from_form(value) when is_atom(value) do
    elixir_module_refs([value])
  end

  defp collect_refs_from_form(_), do: []

  # Filter to only Elixir module atoms (atoms starting with "Elixir.")
  defp elixir_module_refs(atoms) do
    Enum.filter(atoms, fn atom ->
      str = Atom.to_string(atom)
      String.starts_with?(str, "Elixir.") and not String.contains?(str, "-")
    end)
  end

  # Classify how the module is referenced (for diagnostic message)
  defp classify_reference(_caller_mod, target_mod, forms) do
    # Check if it's a behaviour declaration
    behaviours =
      Enum.flat_map(forms, fn
        {:attribute, _, :behaviour, bhv} when is_atom(bhv) -> [bhv]
        {:attribute, _, :behaviour, bhvs} when is_list(bhvs) -> bhvs
        _ -> []
      end)

    cond do
      target_mod in behaviours -> :behaviour
      struct_reference?(target_mod, forms) -> :struct
      true -> :reference
    end
  end

  defp struct_reference?(target_mod, forms) do
    # Check if the module appears in a map pattern with __struct__ key
    forms
    |> collect_struct_refs()
    |> Enum.member?(target_mod)
  end

  defp collect_struct_refs(form) when is_tuple(form) do
    case form do
      {:map, _, fields} ->
        struct_mod =
          Enum.find_value(fields, fn
            {:map_field_exact, _, {:atom, _, :__struct__}, {:atom, _, mod}} -> mod
            _ -> nil
          end)

        refs = form |> Tuple.to_list() |> Enum.flat_map(&collect_struct_refs/1)

        case struct_mod do
          nil -> refs
          mod -> [mod | refs]
        end

      _ ->
        form
        |> Tuple.to_list()
        |> Enum.flat_map(&collect_struct_refs/1)
    end
  end

  defp collect_struct_refs(form) when is_list(form) do
    Enum.flat_map(form, &collect_struct_refs/1)
  end

  defp collect_struct_refs(_), do: []

  defp build_diagnostic(caller_mod, target_mod, ref_type) do
    caller_name = AST.module_name(caller_mod)
    target_name = AST.module_name(target_mod)

    type_desc =
      case ref_type do
        :behaviour -> "declares @behaviour #{target_name}"
        :struct -> "references %#{target_name}{} struct"
        :reference -> "references #{target_name}"
      end

    Diagnostic.info("4.26",
      title: "Phantom dependency",
      message: "#{caller_name} #{type_desc} but never calls any of its functions",
      why:
        "After macro expansion and compilation, #{caller_name} references " <>
          "#{target_name} (as a #{ref_type}) but makes zero function calls to it. " <>
          "This may be a leftover from a refactor, an unused alias/import, or a " <>
          "compile-time-only dependency. Phantom dependencies add noise to the " <>
          "dependency graph and may trigger unnecessary recompilation.",
      alternatives: [
        Fix.new(
          summary: "Remove the unused reference",
          detail:
            "If #{target_name} is no longer needed, remove the alias, import, " <>
              "or use declaration from #{caller_name}.",
          applies_when: "The reference is a leftover from a refactor."
        ),
        Fix.new(
          summary: "Accept if compile-time only",
          detail:
            "If #{target_name} provides macros (use), types (@type), or struct " <>
              "patterns used only in specs, the compile-time reference is intentional.",
          applies_when: "The module provides compile-time functionality only."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#4.26"],
      context: %{
        caller: caller_name,
        target: target_name,
        reference_type: ref_type
      },
      file: "lib",
      line: 0
    )
  end
end
