defmodule Archdo.Rules.Module.ShadowedClauseTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ShadowedClause

  describe "function clauses" do
    test "flags bare variable before specific pattern" do
      code = ~S"""
      defmodule MyApp.Handler do
        def process(event) do
          {:generic, event}
        end

        def process(%{type: :click} = event) do
          {:click, event}
        end
      end
      """

      diags = assert_flagged(ShadowedClause, code)
      assert hd(diags).rule_id == "6.54"
      assert hd(diags).message =~ "shadows"
    end

    test "flags underscore before specific pattern" do
      code = ~S"""
      defmodule MyApp.Handler do
        def handle(_msg, state) do
          {:noreply, state}
        end

        def handle({:tick, _}, state) do
          {:noreply, process(state)}
        end
      end
      """

      assert_flagged(ShadowedClause, code)
    end

    test "allows specific before general (correct order)" do
      code = ~S"""
      defmodule MyApp.Handler do
        def process(%{type: :click} = event), do: {:click, event}
        def process(%{type: :submit} = event), do: {:submit, event}
        def process(event), do: {:generic, event}
      end
      """

      assert_clean(ShadowedClause, code)
    end

    test "allows same literal in different clauses" do
      code = ~S"""
      defmodule MyApp.Handler do
        def status(:active), do: "Active"
        def status(:inactive), do: "Inactive"
        def status(_), do: "Unknown"
      end
      """

      assert_clean(ShadowedClause, code)
    end

    test "allows variable reuse across params (equality constraint)" do
      code = ~S"""
      defmodule MyApp.Compare do
        def equal?(same, same), do: true
        def equal?(_, _), do: false
      end
      """

      assert_clean(ShadowedClause, code)
    end

    test "allows different arity functions with same name" do
      code = ~S"""
      defmodule MyApp.Config do
        def get(key), do: get(key, nil)
        def get(key, default), do: Map.get(@config, key, default)
      end
      """

      assert_clean(ShadowedClause, code)
    end
  end

  describe "case clauses" do
    test "flags empty map before keyed map in case" do
      code = ~S"""
      defmodule MyApp.Handler do
        def process(data) do
          case data do
            %{} -> :any_map
            %{type: :special} -> :special
          end
        end
      end
      """

      diags = assert_flagged(ShadowedClause, code)
      assert hd(diags).message =~ "shadows"
    end

    test "flags tagged tuple catch-all before specific" do
      code = ~S"""
      defmodule MyApp.Handler do
        def handle(result) do
          case result do
            {:ok, value} -> process(value)
            {:ok, %User{}} -> process_user(value)
          end
        end
      end
      """

      diags = assert_flagged(ShadowedClause, code)
      assert hd(diags).message =~ "shadows"
    end

    test "allows specific tuples before general" do
      code = ~S"""
      defmodule MyApp.Handler do
        def handle(result) do
          case result do
            {:ok, %User{} = user} -> process_user(user)
            {:ok, value} -> process(value)
            {:error, reason} -> handle_error(reason)
          end
        end
      end
      """

      assert_clean(ShadowedClause, code)
    end

    test "allows different tags (no shadowing)" do
      code = ~S"""
      defmodule MyApp.Handler do
        def handle(result) do
          case result do
            {:ok, value} -> value
            {:error, reason} -> raise reason
          end
        end
      end
      """

      assert_clean(ShadowedClause, code)
    end
  end

  describe "map patterns" do
    test "flags map with fewer keys before map with more keys" do
      code = ~S"""
      defmodule MyApp.Handler do
        def process(data) do
          case data do
            %{type: _} -> :has_type
            %{type: _, name: _} -> :has_type_and_name
          end
        end
      end
      """

      diags = assert_flagged(ShadowedClause, code)
      assert hd(diags).message =~ "shadows"
    end

    test "allows map with more keys before map with fewer" do
      code = ~S"""
      defmodule MyApp.Handler do
        def process(data) do
          case data do
            %{type: _, name: _} -> :has_type_and_name
            %{type: _} -> :has_type
          end
        end
      end
      """

      assert_clean(ShadowedClause, code)
    end
  end

  describe "guards" do
    test "allows disjoint type guards (is_binary vs is_list)" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) when is_binary(input), do: parse_string(input)
        def parse(input) when is_list(input), do: parse_list(input)
        def parse(input) when is_integer(input), do: parse_int(input)
      end
      """

      assert_clean(ShadowedClause, code)
    end

    test "flags unguarded before guarded (unguarded shadows everything)" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input), do: {:generic, input}
        def parse(input) when is_binary(input), do: parse_string(input)
      end
      """

      assert_flagged(ShadowedClause, code)
    end

    test "allows guarded clause with same pattern when guard narrows" do
      code = ~S"""
      defmodule MyApp.Validator do
        def validate(n) when is_integer(n) and n > 0, do: :positive
        def validate(n) when is_integer(n), do: :non_positive
        def validate(_), do: :not_integer
      end
      """

      # The first two share is_integer but the first has `and n > 0`.
      # Both have guards → check type guards → both have is_integer → not disjoint.
      # But the first has a narrower guard. This is a valid pattern.
      # Our rule will see same type guards (not disjoint) and check patterns.
      # Both have bare variable `n` — but both are guarded, so the unguarded
      # catch-all check won't fire for the first clause.
      # Limitation: this is an edge case where deeper guard analysis would help.
      # For now: guarded clauses with overlapping types but different additional
      # constraints are accepted because the earlier one has a guard.
      assert_clean(ShadowedClause, code)
    end
  end

  describe "scope-aware extraction (BUG-5 from hexpm)" do
    test "does not conflate same-named def across separate defimpl blocks" do
      # Each defimpl creates a separate impl module; identical function names
      # for different :for types are not shadowing each other.
      code = ~S"""
      defmodule MyApp.Email.Formatters do
        defimpl MyApp.Formatter, for: MyApp.User do
          def format(user, _opts), do: {:user, user.id}
        end

        defimpl MyApp.Formatter, for: MyApp.Email do
          def format(email, _opts), do: {:email, email.address}
        end
      end
      """

      assert_clean(ShadowedClause, code)
    end

    test "does not conflate def across compile-time if Mix.env branches" do
      code = ~S"""
      defmodule MyApp.EnvDispatch do
        if Mix.env() == :prod do
          def shutdown(), do: :graceful
        else
          def shutdown(), do: :immediate
        end
      end
      """

      assert_clean(ShadowedClause, code)
    end
  end

  describe "skips test files" do
    test "ignores patterns in test files" do
      code = ~S"""
      defmodule MyApp.HandlerTest do
        use ExUnit.Case

        def helper(x), do: x
        def helper(%{type: :specific}), do: :specific
      end
      """

      assert_clean(ShadowedClause, code, file: "test/handler_test.exs")
    end
  end
end
