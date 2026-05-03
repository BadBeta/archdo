defmodule Archdo.Integration.RealProjectTest do
  @moduledoc """
  Integration tests that run Archdo against real Elixir projects cloned to /tmp.
  Each test locks to a specific commit SHA to ensure reproducibility.

  These tests are excluded by default (`test_helper.exs` excludes
  `:integration`). To run them, populate the repos and use:

      mix test --include integration

  Required repos and commits are listed in `@repos` below. Missing or
  wrong-commit repos cause the corresponding test to be SKIPPED with a
  visible notice — not failed — because the test's assertions only
  make sense against the locked-version source.
  """
  use ExUnit.Case

  # Locked commits — tests are only valid at these exact versions
  @repos %{
    oban: {"/tmp/oban", "38f1af3eb45b679ef089b06deb411e067ff16ed9"},
    broadway: {"/tmp/broadway", "dd2f40571ac463bbc56f949b6c1f8d33fd6cc665"},
    gen_lsp: {"/tmp/gen_lsp", "4b91b92a44c4023b6ccb27e0b6eb2e6647a58cf5"},
    finch: {"/tmp/finch", "358620e9d73cabbe450674c865a6fe3c4ed1361a"},
    nimble_pool: {"/tmp/nimble_pool", "ca7e7bd14936dcf9c1d9a21e08bad092cccd99cc"},
    nimble_options: {"/tmp/nimble_options", "f16af25ba00eb199f76718dcd6968acd3533ed19"},
    phoenix_pubsub: {"/tmp/phoenix_pubsub", "0b63dce1765de0cb3f57f6c7e5cc6b4fc9ef0d98"},
    req: {"/tmp/req", "38c6093a2001736f1a30152df49133a5e036f0b2"},
    wallaby: {"/tmp/wallaby", "6ba1e2e7b71af8b988d98d3bb5016a60369b3585"},
    ecto_job: {"/tmp/ecto_job", "0d02d33e354df66a1f27a030edd6c37a8a96d1ef"}
  }

  # --- Helpers ---

  # §§ elixir-implementing: §6 (compile-time helper) — defmacrop wraps each
  # test body so missing-repo cases visibly SKIP instead of failing the
  # suite. ExUnit has no built-in runtime-skip; the visible IO.puts +
  # vacuous-pass is the standard idiom for opt-in environment-dependent
  # tests where assertions only have meaning against the locked source.
  defmacrop skip_unless_available(name, do: body) do
    quote do
      case repo_available?(unquote(name)) do
        true ->
          unquote(body)

        false ->
          IO.puts("\n  → SKIP integration test: /tmp/#{unquote(name)} missing or wrong commit")
      end
    end
  end

  defp repo_available?(name) do
    {path, expected_sha} = @repos[name]

    File.dir?(Path.join(path, ".git")) and
      repo_at_commit?(path, expected_sha)
  end

  defp repo_at_commit?(path, expected_sha) do
    case System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha) == expected_sha
      _ -> false
    end
  end

  defp run_archdo(name, opts \\ []) do
    {path, _} = @repos[name]
    lib_path = Path.join(path, "lib")
    Archdo.run([lib_path], opts)
  end

  defp findings_for_rule(diagnostics, rule_id) do
    Enum.filter(diagnostics, &(&1.rule_id == rule_id))
  end

  # --- Seam Integrity (4.17) ---

  @tag :integration
  test "oban: zero seam integrity findings" do
    skip_unless_available :oban do
      diagnostics = run_archdo(:oban)
      seam_findings = findings_for_rule(diagnostics, "4.17")

      assert seam_findings == [],
             "Expected 0 seam integrity findings on oban, got #{length(seam_findings)}"
    end
  end

  @tag :integration
  test "broadway: zero seam integrity findings (multi-alias fix)" do
    skip_unless_available :broadway do
      diagnostics = run_archdo(:broadway)
      seam_findings = findings_for_rule(diagnostics, "4.17")

      assert seam_findings == [],
             "Expected 0 seam integrity findings on broadway, got #{length(seam_findings)}"
    end
  end

  @tag :integration
  test "nimble_pool: zero false positives for behaviour_size (optional_callbacks fix)" do
    skip_unless_available :nimble_pool do
      diagnostics = run_archdo(:nimble_pool)
      behaviour_findings = findings_for_rule(diagnostics, "4.1")

      assert behaviour_findings == [],
             "Expected 0 behaviour_size findings on nimble_pool, got #{length(behaviour_findings)}"
    end
  end

  # --- External Dependencies (4.4) ---

  @tag :integration
  test "finch: detects real external dep (Mint.HTTP) without self-call false positives" do
    skip_unless_available :finch do
      diagnostics = run_archdo(:finch)
      ext_dep_findings = findings_for_rule(diagnostics, "4.4")

      # Should find Mint.HTTP as a real external dependency
      mint_findings =
        Enum.filter(ext_dep_findings, fn d ->
          d.message =~ "Mint" or (is_map(d.context) and d.context[:service] =~ "Mint")
        end)

      assert [_ | _] = mint_findings,
             "Expected at least 1 external dep finding for Mint in finch"

      # Should NOT flag Finch calling itself
      self_call_findings =
        Enum.filter(ext_dep_findings, fn d ->
          d.message =~ "Finch" and not (d.message =~ "Mint")
        end)

      assert self_call_findings == [],
             "Finch should not flag itself as external dep, got #{length(self_call_findings)}"
    end
  end

  # --- General: no crashes on real projects ---

  @tag :integration
  test "nimble_options: runs without crashing" do
    skip_unless_available :nimble_options do
      diagnostics = run_archdo(:nimble_options)
      assert is_list(diagnostics)
    end
  end

  @tag :integration
  test "phoenix_pubsub: runs without crashing" do
    skip_unless_available :phoenix_pubsub do
      diagnostics = run_archdo(:phoenix_pubsub)
      assert is_list(diagnostics)
    end
  end

  @tag :integration
  test "req: runs without crashing" do
    skip_unless_available :req do
      diagnostics = run_archdo(:req)
      assert is_list(diagnostics)
    end
  end

  @tag :integration
  test "wallaby: runs without crashing" do
    skip_unless_available :wallaby do
      diagnostics = run_archdo(:wallaby)
      assert is_list(diagnostics)
    end
  end

  @tag :integration
  test "ecto_job: runs without crashing" do
    skip_unless_available :ecto_job do
      diagnostics = run_archdo(:ecto_job)
      assert is_list(diagnostics)
    end
  end

  # --- Diagnostic quality checks ---

  @tag :integration
  test "all diagnostics from oban have required fields" do
    skip_unless_available :oban do
      diagnostics = run_archdo(:oban)

      for d <- diagnostics do
        assert is_binary(d.rule_id) and d.rule_id != "", "Missing rule_id"
        assert d.severity in [:error, :warning, :info], "Invalid severity: #{d.severity}"
        assert is_binary(d.title) and d.title != "", "Missing title"
        assert is_binary(d.message) and d.message != "", "Missing message"
        assert is_binary(d.why) and d.why != "", "Missing why"
        assert is_binary(d.file) and d.file != "", "Missing file"
        assert is_integer(d.line) and d.line >= 0, "Invalid line: #{d.line}"
        assert is_list(d.alternatives), "alternatives not a list"
      end
    end
  end

  @tag :integration
  test "diagnostics are sorted by severity then file" do
    skip_unless_available :oban do
      diagnostics = run_archdo(:oban)

      severity_values = %{error: 0, warning: 1, info: 2}

      sorted? =
        diagnostics
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.all?(fn [a, b] ->
          {severity_values[a.severity], a.file, a.line} <=
            {severity_values[b.severity], b.file, b.line}
        end)

      assert sorted?, "Diagnostics should be sorted by severity, then file, then line"
    end
  end
end
