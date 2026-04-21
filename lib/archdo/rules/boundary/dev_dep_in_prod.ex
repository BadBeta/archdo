defmodule Archdo.Rules.Boundary.DevDepInProd do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{Diagnostic, Fix}

  @impl true
  def id, do: "4.29"

  @impl true
  def description, do: "Dev/test dependency missing `only:` option — will be included in production releases"

  # Well-known dev/test-only packages that should never ship to prod
  @dev_only_deps [
    :credo, :dialyxir, :ex_doc, :excoveralls, :mix_test_watch, :mix_audit,
    :sobelow, :doctor, :ex_check, :stream_data, :benchee, :mox, :mimic,
    :hammox, :bypass, :mock, :ex_machina, :faker, :floki, :wallaby,
    :phoenix_live_reload, :esbuild, :tailwind, :dart_sass
  ]

  @impl true
  def analyze(file, ast, _opts) do
    case mix_exs?(file) do
      true -> check_deps(file, ast)
      false -> []
    end
  end

  defp mix_exs?(file) do
    String.ends_with?(file, "mix.exs")
  end

  defp check_deps(file, ast) do
    {_, diagnostics} =
      Macro.prewalk(ast, [], fn
        # 3-element dep tuple: {:name, "version", opts}
        {:{}, meta, [
          {:__block__, _, [dep_name]},
          _version,
          opts
        ]} = node, acc when is_atom(dep_name) and is_list(opts) ->
          case dev_only_without_only?(dep_name, opts) do
            true ->
              {node, [build_diagnostic(file, meta_line(meta), dep_name) | acc]}

            false ->
              {node, acc}
          end

        # 2-element dep tuple (no opts at all): {:name, "version"}
        {:__block__, meta, [
          {{:__block__, _, [dep_name]}, _version}
        ]} = node, acc when is_atom(dep_name) ->
          case dep_name in @dev_only_deps do
            true ->
              {node, [build_diagnostic(file, meta_line(meta), dep_name) | acc]}

            false ->
              {node, acc}
          end

        # 2-element dep tuple without __block__ wrapper
        {:{}, meta, [
          {:__block__, _, [dep_name]},
          _version
        ]} = node, acc when is_atom(dep_name) ->
          case dep_name in @dev_only_deps do
            true ->
              {node, [build_diagnostic(file, meta_line(meta), dep_name) | acc]}

            false ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(diagnostics)
  end

  defp dev_only_without_only?(dep_name, opts) do
    dep_name in @dev_only_deps and not has_only_option?(opts)
  end

  defp has_only_option?(opts) do
    Enum.any?(opts, fn
      {{:__block__, _, [:only]}, _} -> true
      {:only, _} -> true
      _ -> false
    end)
  end

  defp meta_line(meta) do
    case Keyword.get(meta, :line) do
      nil -> 0
      line -> line
    end
  end

  defp build_diagnostic(file, line, dep_name) do
    Diagnostic.warning("4.29",
      title: "Dev dependency without `only:` option",
      message: ":#{dep_name} is a dev/test tool but has no `only:` restriction — it will be included in production releases",
      why:
        "Dependencies without `only: :dev` or `only: [:dev, :test]` are compiled into " <>
          "production releases. Dev tools like Credo, Dialyxir, and ExDoc add unnecessary " <>
          "code, increase release size, and may expose dev-only functionality in production.",
      alternatives: [
        Fix.new(
          summary: "Add `only:` and `runtime: false`",
          detail:
            "Change `{:#{dep_name}, \"~> x.y\"}` to " <>
              "`{:#{dep_name}, \"~> x.y\", only: [:dev, :test], runtime: false}`",
          applies_when: "The dependency is only needed during development or testing."
        )
      ],
      file: file,
      line: line
    )
  end
end
