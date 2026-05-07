defmodule Archdo.Rules.Module.BangPairInconsistencyTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.BangPairInconsistency

  describe "analyze/3" do
    test "flags `foo!/1` defined without companion `foo/1`" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def fetch_user!(id) do
          {:ok, user} = lookup(id)
          user
        end
      end
      """

      diags =
        assert_flagged(BangPairInconsistency, code, file: "lib/my_app/accounts.ex")

      assert hd(diags).rule_id == "1.35"
    end

    test "ignores when both `foo/1` and `foo!/1` are defined" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def fetch_user(id), do: lookup(id)

        def fetch_user!(id) do
          {:ok, user} = fetch_user(id)
          user
        end
      end
      """

      assert_clean(BangPairInconsistency, code, file: "lib/my_app/accounts.ex")
    end

    test "ignores `foo/0` defined without bang" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def list_users, do: []
      end
      """

      assert_clean(BangPairInconsistency, code, file: "lib/my_app/accounts.ex")
    end

    test "respects arity — flags `foo!/1` even if `foo/2` exists" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def fetch_user(id, opts), do: lookup(id, opts)
        def fetch_user!(id), do: lookup!(id)
      end
      """

      assert_flagged(BangPairInconsistency, code, file: "lib/my_app/accounts.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        def setup_user!(id), do: id
      end
      """

      assert_clean(BangPairInconsistency, code, file: "test/accounts_test.exs")
    end

    test "ignores private bang functions (defp foo!)" do
      code = ~S"""
      defmodule MyApp.Accounts do
        defp normalize!(s), do: String.downcase(s)
      end
      """

      assert_clean(BangPairInconsistency, code, file: "lib/my_app/accounts.ex")
    end

    test "ignores `normalize_*!` — input-coercion convention" do
      # `normalize_*!` is a coercion convention: take raw input,
      # return the normalized value or raise on shape mismatch. The
      # function expresses "make this conform or fail loudly" — there
      # is no useful non-bang form returning ok/error.
      code = ~S"""
      defmodule MyApp.Config do
        def normalize_keyword_or_map!(input, _opts), do: input
        def normalize_positive_integer!(input, _opts), do: input
        def normalize_string_list!(input, _opts), do: input
      end
      """

      assert_clean(BangPairInconsistency, code, file: "lib/my_app/config.ex")
    end

    test "ignores `validate_*!` — input-validation convention" do
      code = ~S"""
      defmodule MyApp.Config do
        def validate_video_target!(input, _opts), do: input
        def validate_children_list!(input, _opts), do: input
        def validate_binary_string!(input, _opts), do: input
      end
      """

      assert_clean(BangPairInconsistency, code, file: "lib/my_app/config.ex")
    end

    test "STILL flags non-coercer `name!/N` without sibling (regression guard)" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def fetch!(id), do: id
      end
      """

      diags = analyze(BangPairInconsistency, code, file: "lib/my_app/accounts.ex")
      assert length(diags) == 1
    end
  end
end
