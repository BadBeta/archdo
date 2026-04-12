defmodule Archdo.Rules.StateMachine.ImplicitBooleanStateTest do
  use Archdo.RuleCase

  alias Archdo.Rules.StateMachine.ImplicitBooleanState

  test "flags schema with many state-like booleans" do
    code = ~S"""
    defmodule MyApp.User do
      use Ecto.Schema

      schema "users" do
        field :name, :string
        field :is_active, :boolean
        field :is_verified, :boolean
        field :is_suspended, :boolean
      end
    end
    """

    diags = assert_flagged(ImplicitBooleanState, code)
    diag = hd(diags)
    assert diag.rule_id == "9.3"
    assert diag.title == "Implicit state machine via boolean flags"
    assert "is_active" in diag.context.boolean_fields
  end

  test "allows schema with few booleans" do
    code = ~S"""
    defmodule MyApp.User do
      use Ecto.Schema

      schema "users" do
        field :name, :string
        field :is_admin, :boolean
      end
    end
    """

    assert_clean(ImplicitBooleanState, code)
  end

  test "ignores non-schema modules" do
    code = ~S"""
    defmodule MyApp.Config do
      defstruct [:is_enabled, :is_active, :is_debug]
    end
    """

    assert_clean(ImplicitBooleanState, code)
  end
end
