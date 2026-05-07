defmodule Archdo.Rules.NIF.NifPanic do
  @moduledoc false
  @behaviour Archdo.Rule

  # Reading the .rs source file IS the responsibility.
  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  # `{:error, _}` on missing/unreadable .rs file → returns `[]` findings.
  # Logging here would be noise on every Elixir-only project.
  Module.register_attribute(__MODULE__, :archdo_silent_error, persist: true)
  @archdo_silent_error true

  alias Archdo.{Diagnostic, Fix}

  # Path segments that mark a Rust source file as NOT NIF code:
  #   - benches/  → Criterion benchmarks (separate Cargo binary)
  #   - src/bin/  → standalone Rust binaries
  #   - examples/ → Cargo example programs
  # Panics in those contexts don't crash the BEAM because they
  # don't run inside it.
  @non_nif_segments [
    ["benches"],
    ["src", "bin"],
    ["examples"]
  ]

  @impl true
  def id, do: "11.3"

  @impl true
  def description, do: "NIF code must not contain panic-inducing patterns"

  # This rule checks .rs files for Rustler NIFs
  # For .ex files, it checks if the module uses Rustler and warns about
  # fallback error handling

  @impl true
  def analyze(file, ast, _opts) do
    case Path.extname(file) do
      ".ex" -> check_rustler_module(file, ast)
      _ -> []
    end
  end

  @doc """
  Analyze a Rust source file for panic-inducing patterns.
  Called separately from the main pipeline for .rs files.

  Skips Rust paths that aren't NIF code: `benches/` (Criterion
  benchmarks compile and run as a separate Cargo binary, not loaded
  into the BEAM), `src/bin/` (standalone Rust binaries), and
  `examples/` (Cargo example programs). Panics there don't crash
  the VM because they don't run inside it.
  """
  def analyze_rust_file(file) do
    case nif_relevant_path?(file) do
      false ->
        []

      true ->
        case File.read(file) do
          {:ok, content} -> check_rust_content(file, content)
          {:error, _} -> []
        end
    end
  end

  # §§ elixir-implementing: §2.1 — multi-clause head with explicit
  # path-segment matches. Each non-NIF context returns false; the
  # default clause returns true.
  defp nif_relevant_path?(file) do
    segments = Path.split(file)
    not Enum.any?(@non_nif_segments, &segment_present?(segments, &1))
  end

  defp segment_present?(segments, ["src", "bin"]) do
    pair_index(segments, "src", "bin") != nil
  end

  defp segment_present?(segments, [single]), do: single in segments

  # Find adjacent `parent` then `child` segments (e.g., "src" → "bin").
  defp pair_index(segments, parent, child) do
    segments
    |> Enum.with_index()
    |> Enum.find_value(fn
      {^parent, i} -> if Enum.at(segments, i + 1) == child, do: i, else: nil
      _ -> nil
    end)
  end

  defp check_rustler_module(file, ast) do
    case uses_rustler?(ast) do
      false ->
        []

      true ->
        project_root = find_project_root(file)

        for rs_file <- Path.wildcard(Path.join(project_root, "native/**/*.rs")),
            nif_relevant_path?(rs_file),
            {:ok, content} <- [File.read(rs_file)],
            diag <- check_rust_content(rs_file, content),
            do: diag
    end
  end

  defp check_rust_content(file, content) do
    lines = String.split(content, "\n")

    {diagnostics, _} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0}, fn {line, line_num}, {diags, test_brace_depth} ->
        trimmed = String.trim(line)

        # Track #[cfg(test)] blocks by counting braces after the attribute.
        # When test_brace_depth > 0, we're inside a test module — skip checks.
        cond do
          trimmed == "#[cfg(test)]" ->
            {diags, -1}

          test_brace_depth == -1 ->
            # Line after #[cfg(test)] — look for opening brace
            opens = count_char(line, ?{)
            closes = count_char(line, ?})
            {diags, max(0, opens - closes)}

          test_brace_depth > 0 ->
            opens = count_char(line, ?{)
            closes = count_char(line, ?})
            {diags, max(0, test_brace_depth + opens - closes)}

          true ->
            {check_line(file, line, line_num) ++ diags, 0}
        end
      end)

    Enum.reverse(diagnostics)
  end

  defp count_char(string, char) do
    for <<byte <- string>>, byte == char, reduce: 0 do
      count -> count + 1
    end
  end

  defp check_line(file, line, line_num) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "//") ->
        []

      String.contains?(line, ".unwrap()") ->
        [panic_diag(file, line_num, :unwrap)]

      String.match?(line, ~r/\.expect\s*\(/) ->
        [panic_diag(file, line_num, :expect)]

      String.match?(line, ~r/panic!\s*\(/) ->
        [panic_diag(file, line_num, :panic_macro)]

      String.match?(line, ~r/(todo|unimplemented)!\s*\(/) ->
        [panic_diag(file, line_num, extract_macro(line))]

      true ->
        []
    end
  end

  defp panic_diag(file, line_num, kind) do
    {message, summary, detail} =
      case kind do
        :unwrap ->
          {".unwrap() in NIF Rust code — panics crash the entire BEAM VM",
           "Replace .unwrap() with `?` and a Result-returning function",
           "Use `.map_err(|e| Error::Term(Box::new(e.to_string())))?` to convert the error into an Elixir " <>
             "error term, or pattern-match on the Result and return an `{:error, reason}` tuple. The Elixir " <>
             "side handles the error like any other tagged tuple."}

        :expect ->
          {".expect() in NIF Rust code — panics crash the entire BEAM VM",
           "Replace .expect() with explicit error handling",
           "Pattern-match on the Result/Option or use combinators like `ok_or_else` to surface the error to " <>
             "Elixir as a tagged tuple. The expect message is lost; bring it through as the error reason."}

        :panic_macro ->
          {"panic!() in NIF Rust code — crashes the entire BEAM VM",
           "Return an error tuple to Elixir instead of panicking",
           "Convert the panic into `Err(Error::Term(...))` so the failure becomes an `{:error, _}` tuple on " <>
             "the Elixir side. The caller can handle it; the VM stays alive."}

        macro when is_binary(macro) ->
          {"#{macro} in NIF Rust code — panics crash the entire BEAM VM",
           "Return `{:error, :not_implemented}` instead of `#{macro}`",
           "`todo!()`/`unimplemented!()` are panic macros — they're convenient placeholders during development " <>
             "but can ship to production. Replace them with an explicit `Err` return so unimplemented paths " <>
             "fail safely instead of crashing the VM."}
      end

    Diagnostic.warning("11.3",
      title: "Panic-inducing pattern in NIF",
      message: message,
      why:
        "NIF Rust code runs in the same OS process as the BEAM. Any Rust panic propagates as a process abort, " <>
          "killing the entire VM along with every process and connection it serves. The same code in " <>
          "non-NIF Rust would just unwind the thread; in a NIF it's a global outage.",
      alternatives: [
        Fix.new(
          summary: summary,
          detail: detail,
          applies_when: "Always — there's no good reason to panic in a NIF."
        )
      ],
      references: ["ARCHITECTURE_RULES.md#11.3"],
      context: %{kind: kind},
      file: file,
      line: line_num
    )
  end

  defp uses_rustler?(ast) do
    Archdo.AST.uses_module?(ast, Rustler) or
      Archdo.AST.uses_module?(ast, RustlerPrecompiled)
  end

  defp find_project_root(file) do
    file
    |> Path.dirname()
    |> find_root_with_mixfile()
  end

  defp find_root_with_mixfile(dir) do
    if File.exists?(Path.join(dir, "mix.exs")) do
      dir
    else
      parent = Path.dirname(dir)

      if parent == dir do
        # Reached filesystem root
        File.cwd!()
      else
        find_root_with_mixfile(parent)
      end
    end
  end

  defp extract_macro(line) do
    cond do
      String.contains?(line, "todo!") -> "todo!()"
      String.contains?(line, "unimplemented!") -> "unimplemented!()"
      true -> "panic macro"
    end
  end
end
