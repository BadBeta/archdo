defmodule Archdo.Rules.OTP.DynamicAtomNameTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.DynamicAtomName

  test "flags String.to_atom" do
    code = ~S"""
    defmodule MyApp.SessionManager do
      def start_link(user_id) do
        name = String.to_atom("session_" <> user_id)
        GenServer.start_link(__MODULE__, user_id, name: name)
      end
    end
    """

    diags = assert_flagged(DynamicAtomName, code)
    diag = hd(diags)
    assert diag.severity == :info
    assert diag.rule_id == "5.24"
    assert diag.title == "Dynamic atom from String.to_atom"
    assert diag.context.kind == :string_to_atom
  end

  test "allows String.to_existing_atom" do
    code = ~S"""
    defmodule MyApp.Config do
      def get(key) do
        String.to_existing_atom(key)
      end
    end
    """

    assert_clean(DynamicAtomName, code)
  end

  test "allows Registry via tuple" do
    code = ~S"""
    defmodule MyApp.SessionManager do
      def start_link(user_id) do
        name = {:via, Registry, {MyApp.Registry, {:session, user_id}}}
        GenServer.start_link(__MODULE__, user_id, name: name)
      end
    end
    """

    assert_clean(DynamicAtomName, code)
  end

  test "ignores Mix tasks parsing CLI args (operational layer)" do
    code = ~S"""
    defmodule Mix.Tasks.MyApp.Sync do
      use Mix.Task
      def run([flag | _]) do
        String.to_atom(flag)
      end
    end
    """

    assert_clean(DynamicAtomName, code, file: "lib/mix/tasks/my_app.sync.ex")
  end
end
