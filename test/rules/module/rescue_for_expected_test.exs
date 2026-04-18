defmodule Archdo.Rules.Module.RescueForExpectedTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.RescueForExpected

  describe "analyze/3" do
    test "flags try/rescue wrapping a bang function" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def get_user(id) do
          try do
            user = MyApp.Repo.get!(MyApp.User, id)
            {:ok, user}
          rescue
            Ecto.NoResultsError -> {:error, :not_found}
          end
        end
      end
      """

      diags = assert_flagged(RescueForExpected, code)
      assert hd(diags).rule_id == "6.14"
      assert hd(diags).message =~ "bang function"
    end

    test "flags try/rescue wrapping Jason.decode!" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse_json(input) do
          try do
            data = Jason.decode!(input)
            {:ok, data}
          rescue
            _ -> {:error, :invalid_json}
          end
        end
      end
      """

      diags = assert_flagged(RescueForExpected, code)
      assert hd(diags).rule_id == "6.14"
    end

    test "allows try/rescue without bang functions" do
      code = ~S"""
      defmodule MyApp.External do
        def call_external(url) do
          try do
            result = :httpc.request(:get, {url, []}, [], [])
            {:ok, result}
          rescue
            e -> {:error, Exception.message(e)}
          end
        end
      end
      """

      assert_clean(RescueForExpected, code)
    end

    test "allows non-bang functions without try/rescue" do
      code = ~S"""
      defmodule MyApp.Accounts do
        def get_user(id) do
          case MyApp.Repo.get(MyApp.User, id) do
            nil -> {:error, :not_found}
            user -> {:ok, user}
          end
        end
      end
      """

      assert_clean(RescueForExpected, code)
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.AccountsTest do
        def helper(id) do
          try do
            MyApp.Repo.get!(MyApp.User, id)
          rescue
            _ -> nil
          end
        end
      end
      """

      assert_clean(RescueForExpected, code, file: "test/accounts_test.exs")
    end
  end
end
