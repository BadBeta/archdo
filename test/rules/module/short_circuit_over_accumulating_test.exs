defmodule Archdo.Rules.Module.ShortCircuitOverAccumulatingTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.ShortCircuitOverAccumulating

  describe "short-circuit `with` in accumulating-flavored functions" do
    test "flags `with` chain in validate_* function" do
      code = ~S"""
      defmodule MyApp.Users do
        def validate_user(attrs) do
          with {:ok, email} <- validate_email(attrs),
               {:ok, password} <- validate_password(attrs),
               {:ok, age} <- validate_age(attrs) do
            {:ok, %{email: email, password: password, age: age}}
          end
        end

        defp validate_email(_), do: {:ok, nil}
        defp validate_password(_), do: {:ok, nil}
        defp validate_age(_), do: {:ok, nil}
      end
      """

      [diag] = assert_flagged(ShortCircuitOverAccumulating, code)
      assert diag.rule_id == "6.95"
      assert diag.severity == :info
      assert diag.message =~ "validate_user"
    end

    test "flags `with` chain in import_* function combining independent extracts" do
      code = ~S"""
      defmodule MyApp.Importer do
        def import_record(row) do
          with {:ok, name} <- extract_name(row),
               {:ok, email} <- extract_email(row),
               {:ok, age} <- extract_age(row) do
            {:ok, %{name: name, email: email, age: age}}
          end
        end

        defp extract_name(_), do: {:ok, nil}
        defp extract_email(_), do: {:ok, nil}
        defp extract_age(_), do: {:ok, nil}
      end
      """

      [diag] = assert_flagged(ShortCircuitOverAccumulating, code)
      assert diag.message =~ "import_record"
    end

    test "flags `with` chain in bulk_* function combining independent extracts" do
      code = ~S"""
      defmodule MyApp.BulkOps do
        def bulk_create(item) do
          with {:ok, title} <- check_title(item),
               {:ok, body} <- check_body(item) do
            {:ok, %{title: title, body: body}}
          end
        end

        defp check_title(_), do: {:ok, nil}
        defp check_body(_), do: {:ok, nil}
      end
      """

      [diag] = assert_flagged(ShortCircuitOverAccumulating, code)
      assert diag.message =~ "bulk_create"
    end

    test "flags `with` chain in check_* function" do
      code = ~S"""
      defmodule MyApp.Validator do
        def check_constraints(form) do
          with {:ok, a} <- check_required(form),
               {:ok, b} <- check_format(form) do
            {:ok, {a, b}}
          end
        end

        defp check_required(form), do: {:ok, form}
        defp check_format(form), do: {:ok, form}
      end
      """

      [diag] = assert_flagged(ShortCircuitOverAccumulating, code)
      assert diag.message =~ "check_constraints"
    end

    test "flags multiple matching functions in same module" do
      code = ~S"""
      defmodule MyApp.Forms do
        def validate_signup(p) do
          with {:ok, a} <- check_email(p),
               {:ok, b} <- check_password(p) do
            {:ok, {a, b}}
          end
        end

        def validate_profile(p) do
          with {:ok, a} <- check_name(p),
               {:ok, b} <- check_bio(p) do
            {:ok, {a, b}}
          end
        end

        defp check_email(p), do: {:ok, p}
        defp check_password(p), do: {:ok, p}
        defp check_name(p), do: {:ok, p}
        defp check_bio(p), do: {:ok, p}
      end
      """

      diagnostics = assert_flagged(ShortCircuitOverAccumulating, code)
      assert length(diagnostics) == 2
    end

    test "flags private validate_* function too" do
      code = ~S"""
      defmodule MyApp.Internal do
        def run(attrs) do
          validate_input(attrs)
        end

        defp validate_input(attrs) do
          with {:ok, a} <- step_one(attrs),
               {:ok, b} <- step_two(attrs) do
            {:ok, {a, b}}
          end
        end

        defp step_one(a), do: {:ok, a}
        defp step_two(a), do: {:ok, a}
      end
      """

      [diag] = assert_flagged(ShortCircuitOverAccumulating, code)
      assert diag.message =~ "validate_input"
    end
  end

  describe "clean code" do
    test "does not flag `with` chain in non-accumulating function" do
      code = ~S"""
      defmodule MyApp.Orders do
        def place_order(user_id, product_id) do
          with {:ok, user} <- fetch_user(user_id),
               {:ok, product} <- fetch_product(product_id),
               {:ok, order} <- create_order(user, product) do
            {:ok, order}
          end
        end

        defp fetch_user(id), do: {:ok, %{id: id}}
        defp fetch_product(id), do: {:ok, %{id: id}}
        defp create_order(u, p), do: {:ok, %{user: u, product: p}}
      end
      """

      assert_clean(ShortCircuitOverAccumulating, code)
    end

    test "does not flag single-clause `with` (different rule territory)" do
      code = ~S"""
      defmodule MyApp.Users do
        def validate_user(attrs) do
          with {:ok, email} <- validate_email(attrs) do
            {:ok, email}
          end
        end

        defp validate_email(_), do: {:ok, nil}
      end
      """

      assert_clean(ShortCircuitOverAccumulating, code)
    end

    test "does not flag accumulating function without `with`" do
      code = ~S"""
      defmodule MyApp.Users do
        def validate_user(attrs) do
          errors =
            []
            |> add_email_error(attrs)
            |> add_password_error(attrs)

          case errors do
            [] -> {:ok, attrs}
            errs -> {:error, errs}
          end
        end

        defp add_email_error(errs, _), do: errs
        defp add_password_error(errs, _), do: errs
      end
      """

      assert_clean(ShortCircuitOverAccumulating, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.UsersTest do
        def validate_user(attrs) do
          with {:ok, a} <- step_a(attrs),
               {:ok, b} <- step_b(attrs) do
            {:ok, {a, b}}
          end
        end

        defp step_a(a), do: {:ok, a}
        defp step_b(a), do: {:ok, a}
      end
      """

      assert_clean(ShortCircuitOverAccumulating, code, file: "test/users_test.exs")
    end

    test "does not flag sequential pipeline whose body uses only one bound name" do
      # Real-world FP: validate_money_positive — the `with` is a sequential
      # dependency chain (need amount before checking positive), and the body
      # uses only one of the bound names.
      code = ~S"""
      defmodule MyApp.Validations do
        def validate_money_positive(changeset, field) do
          with amount when not is_nil(amount) <- get_change(changeset, field),
               true <- Money.positive?(amount) do
            put_change(changeset, field, amount)
          else
            false -> add_error(changeset, field, "must be positive")
            _ -> changeset
          end
        end

        defp get_change(_, _), do: 1
        defp put_change(c, _, _), do: c
        defp add_error(c, _, _), do: c
      end
      """

      assert_clean(ShortCircuitOverAccumulating, code)
    end

    test "does not flag check_*/* sequential API-call pipeline" do
      # Real-world FP: check_repo_permissions — token feeds next API call,
      # body uses only one bound name.
      code = ~S"""
      defmodule MyApp.Webhooks do
        def check_repo_permissions(payload) do
          with {:ok, token} <- Github.get_installation_token(payload["id"]),
               {:ok, perms} <- Github.get_repository_permissions(token, payload) do
            classify(perms)
          end
        end

        defp classify(p), do: {:ok, p}
      end
      """

      assert_clean(ShortCircuitOverAccumulating, code)
    end

    test "does not flag function with prefix-but-not-pattern (validator/1)" do
      # Names like "validator", "importer", "checkbox" don't match the
      # accumulating prefix patterns — only validate_/import_/bulk_/check_ + _ separator.
      code = ~S"""
      defmodule MyApp.Lib do
        def validator(attrs) do
          with {:ok, a} <- step_a(attrs),
               {:ok, b} <- step_b(attrs) do
            {:ok, {a, b}}
          end
        end

        defp step_a(a), do: {:ok, a}
        defp step_b(a), do: {:ok, a}
      end
      """

      assert_clean(ShortCircuitOverAccumulating, code)
    end
  end

  describe "edge cases" do
    test "does not flag a function whose body has no `with`" do
      code = ~S"""
      defmodule MyApp.Users do
        def validate_user(_attrs), do: :ok
      end
      """

      assert_clean(ShortCircuitOverAccumulating, code)
    end

    test "diagnostic context records function name and arrow count" do
      code = ~S"""
      defmodule MyApp.Forms do
        def validate_form(p) do
          with {:ok, a} <- step_a(p),
               {:ok, b} <- step_b(p),
               {:ok, c} <- step_c(p) do
            {:ok, {a, b, c}}
          end
        end

        defp step_a(p), do: {:ok, p}
        defp step_b(p), do: {:ok, p}
        defp step_c(p), do: {:ok, p}
      end
      """

      [diag] = assert_flagged(ShortCircuitOverAccumulating, code)
      assert diag.context.function =~ "validate_form"
      assert diag.context.arrow_count == 3
    end
  end
end
