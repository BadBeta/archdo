defmodule Archdo.MixProject do
  use Mix.Project

  def project do
    [
      app: :archdo,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # `:no_opaque` suppresses dialyzer's opacity checks. Reinstated
      # 2026-05-03 (M-Plan19 follow-up) because dialyzer's MapSet
      # opacity inference produces false positives: success typing
      # pierces `MapSet.t()` at construction sites (e.g.
      # `Freeze.load/1` building from a stream surfaces the concrete
      # `:set` tuple), then every downstream `MapSet.member?` /
      # `MapSet.intersection` etc. is flagged. The codebase's own
      # opacity contract — `Compiled.Graph` is `@opaque`, accessed
      # only via `Archdo.Compiled.X` accessors — is enforced
      # behaviorally by `mix archdo --stats` (Compiled context: 0
      # boundary leaks). Architectural enforcement does not depend
      # on this dialyzer flag.
      dialyzer: [plt_add_apps: [:mix], flags: [:unmatched_returns, :no_opaque]],
      elixirc_paths: elixirc_paths(Mix.env()),
      description:
        "Architectural quality checker for Elixir — checks OTP patterns, boundaries, and test architecture",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:jsv, "~> 0.18"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/BadBeta/archdo",
        "Elixir Skill" => "https://github.com/BadBeta/Elixir_skill"
      }
    ]
  end
end
