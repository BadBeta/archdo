defmodule Archdo.Rules.Module.SecretStructInspectTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.SecretStructInspect

  describe "analyze/3 — flags struct with secret field and no Inspect protection" do
    test "flags struct with :token field" do
      code = ~S"""
      defmodule MyApp.Session do
        defstruct [:id, :user_id, :token, :expires_at]
      end
      """

      diags = assert_flagged(SecretStructInspect, code)
      diag = hd(diags)
      assert diag.severity == :warning
      assert diag.title =~ "Inspect"
      assert diag.message =~ "token"
    end

    test "flags struct with :password_hash field" do
      code = ~S"""
      defmodule MyApp.User do
        defstruct [:id, :email, :password_hash]
      end
      """

      assert_flagged(SecretStructInspect, code)
    end

    test "flags struct with :api_key field" do
      code = ~S"""
      defmodule MyApp.Credential do
        defstruct [:id, :api_key]
      end
      """

      assert_flagged(SecretStructInspect, code)
    end

    test "flags struct with :private_key field" do
      code = ~S"""
      defmodule MyApp.Cert do
        defstruct [:id, :public_key, :private_key]
      end
      """

      assert_flagged(SecretStructInspect, code)
    end

    test "flags struct with :secret field" do
      code = ~S"""
      defmodule MyApp.OAuth do
        defstruct [:client_id, :secret]
      end
      """

      assert_flagged(SecretStructInspect, code)
    end

    test "flags struct with mixed-case substring (refresh_token)" do
      code = ~S"""
      defmodule MyApp.Session do
        defstruct [:id, :refresh_token]
      end
      """

      assert_flagged(SecretStructInspect, code)
    end
  end

  describe "analyze/3 — Inspect protections allow it" do
    test "allows @derive {Inspect, only: [...]} with secret field" do
      code = ~S"""
      defmodule MyApp.Session do
        @derive {Inspect, only: [:id, :user_id]}
        defstruct [:id, :user_id, :token]
      end
      """

      assert_clean(SecretStructInspect, code)
    end

    test "allows @derive {Inspect, except: [:token]} with secret field" do
      code = ~S"""
      defmodule MyApp.Session do
        @derive {Inspect, except: [:token]}
        defstruct [:id, :user_id, :token]
      end
      """

      assert_clean(SecretStructInspect, code)
    end

    test "allows defimpl Inspect, for: __MODULE__ with secret field" do
      code = ~S"""
      defmodule MyApp.Session do
        defstruct [:id, :user_id, :token]

        defimpl Inspect do
          def inspect(%MyApp.Session{id: id}, _opts), do: "#Session<id=" <> to_string(id) <> ">"
        end
      end
      """

      assert_clean(SecretStructInspect, code)
    end
  end

  describe "analyze/3 — non-sensitive structs allowed" do
    test "no flag for struct without sensitive fields" do
      code = ~S"""
      defmodule MyApp.Order do
        defstruct [:id, :total, :status]
      end
      """

      assert_clean(SecretStructInspect, code)
    end

    test "no flag for struct with similarly-named-but-not-secret field (token_count)" do
      code = ~S"""
      defmodule MyApp.Stats do
        defstruct [:id, :token_count, :request_count]
      end
      """

      # token_count is NOT a secret — must not match. Substring check is too
      # broad if it triggers on this.
      assert_clean(SecretStructInspect, code)
    end
  end

  describe "analyze/3 — file scoping" do
    test "skips test files" do
      code = ~S"""
      defmodule MyApp.SessionTest do
        defstruct [:id, :token]
      end
      """

      assert analyze(SecretStructInspect, code, file: "test/my_app/session_test.exs") == []
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert SecretStructInspect.id() == "5.54"
    end

    test "description mentions Inspect" do
      assert SecretStructInspect.description() =~ "Inspect"
    end
  end
end
