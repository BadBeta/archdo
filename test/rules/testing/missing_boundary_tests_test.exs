defmodule Archdo.Rules.Testing.MissingBoundaryTestsTest do
  use ExUnit.Case, async: true

  alias Archdo.Rules.Testing.MissingBoundaryTests

  defp parse(code, file) do
    {:ok, ast} = Code.string_to_quoted(code, file: file, columns: true, token_metadata: true)
    {file, ast}
  end

  defp make_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "archdo_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "analyze_project/1" do
    test "flags context facade with low test coverage" do
      tmp_dir = make_tmp_dir()
      facade_file = Path.join(tmp_dir, "lib/my_app/accounts.ex")
      facade_dir = Path.join(tmp_dir, "lib/my_app/accounts")
      test_file = Path.join(tmp_dir, "test/my_app/accounts_test.exs")

      File.mkdir_p!(facade_dir)
      File.mkdir_p!(Path.dirname(test_file))

      # Source with 10 public functions
      source_code = """
      defmodule MyApp.Accounts do
        def get_user(id), do: id
        def create_user(attrs), do: attrs
        def update_user(user, attrs), do: {user, attrs}
        def delete_user(user), do: user
        def list_users, do: []
        def authenticate(email, pass), do: {email, pass}
        def change_password(user, pass), do: {user, pass}
        def reset_password(token), do: token
        def confirm_user(token), do: token
        def suspend_user(user), do: user
      end
      """

      # Test that only exercises 2 functions
      test_code = """
      defmodule MyApp.AccountsTest do
        use ExUnit.Case

        describe "get_user/1" do
          test "returns user" do
            assert MyApp.Accounts.get_user(1) == 1
          end
        end

        describe "create_user/1" do
          test "creates user" do
            assert MyApp.Accounts.create_user(%{}) == %{}
          end
        end
      end
      """

      File.write!(facade_file, source_code)

      source_ast = parse(source_code, facade_file)
      test_ast = parse(test_code, test_file)

      diags = MissingBoundaryTests.analyze_project([source_ast, test_ast])
      assert length(diags) == 1
      [diag] = diags
      assert diag.rule_id == "7.28"
      assert diag.message =~ "10 public functions"
      assert diag.message =~ "Accounts"
    end

    test "skips modules with fewer than 8 public functions" do
      tmp_dir = make_tmp_dir()
      facade_file = Path.join(tmp_dir, "lib/my_app/settings.ex")
      facade_dir = Path.join(tmp_dir, "lib/my_app/settings")

      File.mkdir_p!(facade_dir)

      source_code = """
      defmodule MyApp.Settings do
        def get(key), do: key
        def set(key, val), do: {key, val}
        def delete(key), do: key
      end
      """

      source_ast = parse(source_code, facade_file)

      diags = MissingBoundaryTests.analyze_project([source_ast])
      assert diags == []
    end

    test "skips modules without corresponding directory" do
      source_code = """
      defmodule MyApp.Helpers do
        def one, do: 1
        def two, do: 2
        def three, do: 3
        def four, do: 4
        def five, do: 5
        def six, do: 6
        def seven, do: 7
        def eight, do: 8
        def nine, do: 9
      end
      """

      # Use a path that won't have a matching directory
      source_ast = parse(source_code, "/tmp/nonexistent_archdo_path/lib/my_app/helpers.ex")

      diags = MissingBoundaryTests.analyze_project([source_ast])
      assert diags == []
    end
  end
end
