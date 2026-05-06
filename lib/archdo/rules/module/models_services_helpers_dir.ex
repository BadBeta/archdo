defmodule Archdo.Rules.Module.ModelsServicesHelpersDir do
  @moduledoc false
  @behaviour Archdo.Rule

  alias Archdo.{AST, Diagnostic, Fix}

  @impl true
  def id, do: "1.34"

  @impl true
  def description,
    do:
      "File under `lib/<app>/{models,services,helpers}/` — anti-pattern naming " <>
        "imported from MVC frameworks; use domain-named context directories"

  @impl true
  def analyze(file, _ast, _opts) do
    case AST.test_file?(file) do
      true -> []
      false -> check_path(file)
    end
  end

  defp check_path(file) do
    case classify_path(file) do
      nil -> []
      {kind, dir} -> [build_diagnostic(file, kind, dir)]
    end
  end

  # The web layer (`lib/<app>_web/`) follows different conventions —
  # `helpers/`, `views/`, `controllers/` are idiomatic Phoenix scaffolding.
  defp classify_path(file) do
    case Path.split(file) do
      ["lib", app | rest] -> classify_segments(rest, web_app?(app))
      _ -> nil
    end
  end

  defp web_app?(app) when is_binary(app), do: String.ends_with?(app, "_web")
  defp web_app?(_), do: false

  defp classify_segments(segments, web_layer?) do
    Enum.find_value(segments, fn seg ->
      case seg do
        "models" -> {:models, "models"}
        "services" -> {:services, "services"}
        "helpers" -> maybe_helpers(web_layer?)
        _ -> nil
      end
    end)
  end

  defp maybe_helpers(true), do: nil
  defp maybe_helpers(false), do: {:helpers, "helpers"}

  defp build_diagnostic(file, kind, dir) do
    Diagnostic.warning("1.34",
      title: "`#{dir}/` directory — MVC-style layout, not idiomatic Elixir",
      message:
        "File lives under `#{dir}/`. Elixir code is organized by domain (contexts), " <>
          "not by technical layer (`models`, `services`, `helpers`). Names like " <>
          "`Accounts`, `Catalog`, `Billing` scream the domain; `models`, `services`, " <>
          "`helpers` scream the framework.",
      why: rationale(kind),
      alternatives: [
        Fix.new(
          summary: "Reorganize files by context (domain), not by layer",
          detail:
            "# BEFORE — layered:\n" <>
              "lib/my_app/models/user.ex          # User schema\n" <>
              "lib/my_app/models/order.ex         # Order schema\n" <>
              "lib/my_app/services/billing.ex     # Billing service\n" <>
              "lib/my_app/services/orders.ex      # Order service\n" <>
              "lib/my_app/helpers/money.ex        # Money helpers\n\n" <>
              "# AFTER — by context:\n" <>
              "lib/my_app/accounts.ex             # Accounts context (public API)\n" <>
              "lib/my_app/accounts/user.ex        # User schema (internal)\n" <>
              "lib/my_app/billing.ex              # Billing context\n" <>
              "lib/my_app/billing/charge.ex       # Charge logic\n" <>
              "lib/my_app/orders.ex               # Orders context\n" <>
              "lib/my_app/orders/order.ex         # Order schema\n" <>
              "lib/my_app/money.ex                # Money value-type module",
          applies_when:
            "Always — the directory name should describe the bounded context, not the technical role of the file."
        )
      ],
      references: [
        "elixir-implementing/SKILL.md#10.9",
        "elixir-planning/SKILL.md#1.7",
        "elixir-planning/SKILL.md#1.8"
      ],
      context: %{kind: kind, dir: dir},
      file: file,
      line: 1
    )
  end

  defp rationale(:models),
    do:
      "`models/` is an MVC-framework convention (Rails, Django). It encourages " <>
        "anemic domain objects — schemas with no behavior — and pushes business " <>
        "logic into `services/` or controllers. Elixir contexts deliberately " <>
        "co-locate the schema and the operations on it: `MyApp.Accounts.User` lives " <>
        "next to `MyApp.Accounts` (the context module). Splitting them by directory " <>
        "buries the relationship."

  defp rationale(:services),
    do:
      "`services/` is a Java/Spring naming convention. In Elixir, the context " <>
        "module IS the service — `MyApp.Billing` is both the public API and the " <>
        "place where Billing's business logic lives. A `MyApp.Services.Billing` " <>
        "doubles up the namespace and tells you nothing about the domain."

  defp rationale(:helpers),
    do:
      "`helpers/` is a catch-all that grows into a junk drawer. Each \"helper\" " <>
        "either belongs to a specific context (move it inside that context, e.g., " <>
        "`MyApp.Accounts.UserHelpers`) or is a value type / utility module that " <>
        "should be named for what it does (`MyApp.Money`, `MyApp.Slug`). Web-layer " <>
        "view helpers (under `lib/my_app_web/helpers/`) are different — that's a " <>
        "Phoenix convention and not flagged here."
end
