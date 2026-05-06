defmodule Archdo.Rules.Module.HandRolledTokenCryptoTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.HandRolledTokenCrypto

  describe "analyze/3" do
    test "flags :crypto.mac in a Token module" do
      code = ~S"""
      defmodule MyApp.Token do
        @secret "hardcoded"

        def sign(payload) do
          :crypto.mac(:hmac, :sha256, @secret, payload)
        end
      end
      """

      diags = assert_flagged(HandRolledTokenCrypto, code, file: "lib/my_app/token.ex")
      assert hd(diags).rule_id == "6.94"
    end

    test "flags :crypto.hash in an Auth module" do
      code = ~S"""
      defmodule MyApp.Auth do
        def hash(password) do
          :crypto.hash(:sha256, password)
        end
      end
      """

      assert_flagged(HandRolledTokenCrypto, code, file: "lib/my_app/auth.ex")
    end

    test "flags :crypto.hmac in a Session module" do
      code = ~S"""
      defmodule MyApp.Session do
        def sign(data, secret) do
          :crypto.hmac(:sha256, secret, data)
        end
      end
      """

      assert_flagged(HandRolledTokenCrypto, code, file: "lib/my_app/session.ex")
    end

    test "ignores :crypto.hash in a non-auth module (e.g., content addressing)" do
      code = ~S"""
      defmodule MyApp.Storage do
        def fingerprint(blob), do: :crypto.hash(:sha256, blob)
      end
      """

      assert_clean(HandRolledTokenCrypto, code, file: "lib/my_app/storage.ex")
    end

    test "ignores guardian / bcrypt / argon2 / plug_crypto wrappers" do
      code = ~S"""
      defmodule MyApp.Auth do
        def hash(pw), do: Bcrypt.hash_pwd_salt(pw)
        def sign(claims), do: Guardian.encode_and_sign(claims)
        def compare(a, b), do: Plug.Crypto.secure_compare(a, b)
      end
      """

      assert_clean(HandRolledTokenCrypto, code, file: "lib/my_app/auth.ex")
    end

    test "skips test files" do
      code = ~S"""
      defmodule MyApp.TokenTest do
        def fixture, do: :crypto.mac(:hmac, :sha256, "k", "v")
      end
      """

      assert_clean(HandRolledTokenCrypto, code, file: "test/token_test.exs")
    end
  end
end
