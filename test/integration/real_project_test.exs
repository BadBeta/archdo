defmodule Archdo.Integration.RealProjectTest do
  @moduledoc """
  Integration tests that run Archdo against real Elixir projects cloned to /tmp.
  Each test locks to a specific commit SHA to ensure reproducibility.
  If a repo is missing or at the wrong commit, the test is skipped.
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
    unless repo_available?(:oban), do: flunk("oban not at expected commit — skip")

    diagnostics = run_archdo(:oban)
    seam_findings = findings_for_rule(diagnostics, "4.17")
    assert seam_findings == [], "Expected 0 seam integrity findings on oban, got #{length(seam_findings)}"
  end

  @tag :integration
  test "broadway: zero seam integrity findings (multi-alias fix)" do
    unless repo_available?(:broadway), do: flunk("broadway not at expected commit — skip")

    diagnostics = run_archdo(:broadway)
    seam_findings = findings_for_rule(diagnostics, "4.17")
    assert seam_findings == [], "Expected 0 seam integrity findings on broadway, got #{length(seam_findings)}"
  end

  @tag :integration
  test "nimble_pool: zero false positives for behaviour_size (optional_callbacks fix)" do
    unless repo_available?(:nimble_pool), do: flunk("nimble_pool not at expected commit — skip")

    diagnostics = run_archdo(:nimble_pool)
    behaviour_findings = findings_for_rule(diagnostics, "4.1")
    assert behaviour_findings == [],
           "Expected 0 behaviour_size findings on nimble_pool, got #{length(behaviour_findings)}"
  end

  # --- External Dependencies (4.4) ---

  @tag :integration
  test "finch: detects real external dep (Mint.HTTP) without self-call false positives" do
    unless repo_available?(:finch), do: flunk("finch not at expected commit — skip")

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

  # --- General: no crashes on real projects ---

  @tag :integration
  test "nimble_options: runs without crashing" do
    unless repo_available?(:nimble_options), do: flunk("nimble_options not at expected commit — skip")

    diagnostics = run_archdo(:nimble_options)
    assert is_list(diagnostics)
  end

  @tag :integration
  test "phoenix_pubsub: runs without crashing" do
    unless repo_available?(:phoenix_pubsub), do: flunk("phoenix_pubsub not at expected commit — skip")

    diagnostics = run_archdo(:phoenix_pubsub)
    assert is_list(diagnostics)
  end

  @tag :integration
  test "req: runs without crashing" do
    unless repo_available?(:req), do: flunk("req not at expected commit — skip")

    diagnostics = run_archdo(:req)
    assert is_list(diagnostics)
  end

  @tag :integration
  test "wallaby: runs without crashing" do
    unless repo_available?(:wallaby), do: flunk("wallaby not at expected commit — skip")

    diagnostics = run_archdo(:wallaby)
    assert is_list(diagnostics)
  end

  @tag :integration
  test "ecto_job: runs without crashing" do
    unless repo_available?(:ecto_job), do: flunk("ecto_job not at expected commit — skip")

    diagnostics = run_archdo(:ecto_job)
    assert is_list(diagnostics)
  end

  # --- Diagnostic quality checks ---

  @tag :integration
  test "all diagnostics from oban have required fields" do
    unless repo_available?(:oban), do: flunk("oban not at expected commit — skip")

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

  @tag :integration
  test "diagnostics are sorted by severity then file" do
    unless repo_available?(:oban), do: flunk("oban not at expected commit — skip")

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
