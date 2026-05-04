defmodule Archdo.Compiled.DiagramSystemTest do
  use ExUnit.Case, async: true

  alias Archdo.Compiled.DiagramSystem

  defp info(behaviours \\ []), do: %{behaviours: behaviours}

  describe "classify_module/2 — interface layer" do
    # Each marker maps to a representative module name (a literal atom,
    # so no String.to_atom — atoms are never GC'd).
    interface_cases = [
      {"Controller", MyAppWeb.UserController},
      {"Live.", MyAppWeb.Live.Index},
      {"LiveView", MyAppWeb.HomeLiveView},
      {"Channel", MyAppWeb.RoomChannel},
      {"Socket", MyAppWeb.UserSocket},
      {"Endpoint", MyAppWeb.Endpoint},
      {"Router", MyAppWeb.Router},
      {"Plug.", MyApp.Plug.Auth},
      {"Mix.Tasks.", Mix.Tasks.Foo}
    ]

    for {marker, mod} <- interface_cases do
      test "module containing '#{marker}' classifies as :interface" do
        assert :interface = DiagramSystem.classify_module(unquote(mod), info())
      end
    end
  end

  describe "classify_module/2 — infrastructure layer" do
    infra_cases = [
      {".Repo", MyApp.Repo},
      {"Mailer", MyApp.Mailer},
      {".Adapter", MyApp.Stripe.Adapter},
      {".Client", MyApp.Github.Client}
    ]

    for {marker, mod} <- infra_cases do
      test "module containing '#{marker}' classifies as :infrastructure" do
        assert :infrastructure = DiagramSystem.classify_module(unquote(mod), info())
      end
    end
  end

  describe "classify_module/2 — domain default" do
    test "plain module → :domain" do
      assert :domain = DiagramSystem.classify_module(MyApp.Accounts, info())
    end

    test "GenServer module without an interface/infra marker → :domain" do
      assert :domain = DiagramSystem.classify_module(MyApp.Worker, info([GenServer]))
    end

    test "Supervisor module → :domain" do
      assert :domain = DiagramSystem.classify_module(MyApp.Sup, info([Supervisor]))
    end

    test "interface marker beats GenServer behaviour" do
      # If a module ends in Controller AND uses GenServer somehow, the
      # interface classification still wins (markers are checked first).
      assert :interface =
               DiagramSystem.classify_module(MyAppWeb.UserController, info([GenServer]))
    end
  end
end
