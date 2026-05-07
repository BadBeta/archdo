defmodule Archdo.Rules.Module.UnsafeDeserializationTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.UnsafeDeserialization

  describe "analyze/3 — :erlang.binary_to_term" do
    test "flags :erlang.binary_to_term/1 (no opts)" do
      code = ~S"""
      defmodule MyApp.Decoder do
        def decode(payload) do
          :erlang.binary_to_term(payload)
        end
      end
      """

      diags = assert_flagged(UnsafeDeserialization, code)
      diag = hd(diags)
      assert diag.severity == :error
      assert diag.title =~ "binary_to_term"
    end

    test "flags :erlang.binary_to_term/2 without :safe option" do
      code = ~S"""
      defmodule MyApp.Decoder do
        def decode(payload) do
          :erlang.binary_to_term(payload, [:used])
        end
      end
      """

      diags = assert_flagged(UnsafeDeserialization, code)
      assert hd(diags).severity == :error
    end

    test "allows :erlang.binary_to_term/2 with :safe option" do
      code = ~S"""
      defmodule MyApp.Decoder do
        def decode(payload) do
          :erlang.binary_to_term(payload, [:safe])
        end
      end
      """

      assert_clean(UnsafeDeserialization, code)
    end

    test "allows :erlang.binary_to_term/2 with :safe alongside other opts" do
      code = ~S"""
      defmodule MyApp.Decoder do
        def decode(payload) do
          :erlang.binary_to_term(payload, [:safe, :used])
        end
      end
      """

      assert_clean(UnsafeDeserialization, code)
    end
  end

  describe "analyze/3 — Code.eval_*" do
    test "flags Code.eval_string/1" do
      code = ~S"""
      defmodule MyApp.Plugin do
        def run(source) do
          Code.eval_string(source)
        end
      end
      """

      diags = assert_flagged(UnsafeDeserialization, code)
      assert hd(diags).title =~ "Code.eval_string"
    end

    test "flags Code.eval_string/2" do
      code = ~S"""
      defmodule MyApp.Plugin do
        def run(source, bindings) do
          Code.eval_string(source, bindings)
        end
      end
      """

      assert_flagged(UnsafeDeserialization, code)
    end

    test "flags Code.eval_quoted/1" do
      code = ~S"""
      defmodule MyApp.Plugin do
        def run(quoted) do
          Code.eval_quoted(quoted)
        end
      end
      """

      diags = assert_flagged(UnsafeDeserialization, code)
      assert hd(diags).title =~ "Code.eval_quoted"
    end

    test "flags Code.compile_string/1" do
      code = ~S"""
      defmodule MyApp.Plugin do
        def run(source) do
          Code.compile_string(source)
        end
      end
      """

      diags = assert_flagged(UnsafeDeserialization, code)
      assert hd(diags).title =~ "Code.compile_string"
    end
  end

  describe "analyze/3 — Jason.decode!(keys: :atoms)" do
    test "flags Jason.decode! with keys: :atoms" do
      code = ~S"""
      defmodule MyApp.JSON do
        def parse(json) do
          Jason.decode!(json, keys: :atoms)
        end
      end
      """

      diags = assert_flagged(UnsafeDeserialization, code)
      assert hd(diags).title =~ "atoms"
    end

    test "flags Jason.decode (non-bang) with keys: :atoms" do
      code = ~S"""
      defmodule MyApp.JSON do
        def parse(json) do
          Jason.decode(json, keys: :atoms)
        end
      end
      """

      assert_flagged(UnsafeDeserialization, code)
    end

    test "allows Jason.decode! with default (string keys)" do
      code = ~S"""
      defmodule MyApp.JSON do
        def parse(json) do
          Jason.decode!(json)
        end
      end
      """

      assert_clean(UnsafeDeserialization, code)
    end

    test "allows Jason.decode! with keys: :atoms!" do
      code = ~S"""
      defmodule MyApp.JSON do
        def parse(json) do
          Jason.decode!(json, keys: :atoms!)
        end
      end
      """

      assert_clean(UnsafeDeserialization, code)
    end
  end

  describe "analyze/3 — file scoping" do
    test "skips test files" do
      code = ~S"""
      defmodule MyApp.DecoderTest do
        def decode(payload) do
          :erlang.binary_to_term(payload)
        end
      end
      """

      assert analyze(UnsafeDeserialization, code, file: "test/my_app/decoder_test.exs") == []
    end
  end

  describe "Code.eval_* inside `defmacro` body — compile-time, not runtime" do
    # `Code.eval_quoted` inside a `defmacro` body operates at COMPILE
    # TIME on quoted forms supplied by code authors (the calling
    # `__CALLER__` source), NOT runtime user input. Real-world: Ash's
    # `defcomparable`, Ash.TypedStruct — Sobelow has the same exemption.

    test "does NOT fire on `Code.eval_quoted` inside `defmacro` body" do
      code = ~S"""
      defmodule MyApp.TypedStruct do
        defmacro defcomparable({:"::", _, [_, quoted_type]}, do: code) do
          {type, []} = Code.eval_quoted(quoted_type, [], __CALLER__)
          quote do
            unquote(type)
            unquote(code)
          end
        end
      end
      """

      assert_clean(UnsafeDeserialization, code, file: "lib/my_app/typed_struct.ex")
    end

    test "does NOT fire on `Code.eval_quoted` inside `defmacrop` body" do
      code = ~S"""
      defmodule MyApp.M do
        defmacrop helper(quoted) do
          {value, []} = Code.eval_quoted(quoted, [], __CALLER__)
          quote do: unquote(value)
        end
      end
      """

      assert_clean(UnsafeDeserialization, code, file: "lib/my_app/m.ex")
    end

    test "STILL fires on `Code.eval_quoted` outside any defmacro" do
      # Regression guard: runtime Code.eval_quoted IS a real RCE vector.
      code = ~S"""
      defmodule MyApp.Risky do
        def run_template(quoted_form) do
          Code.eval_quoted(quoted_form, [], __ENV__)
        end
      end
      """

      assert_flagged(UnsafeDeserialization, code, file: "lib/my_app/risky.ex")
    end

    test "does NOT fire on `Code.eval_quoted` inside `quote do ... end` block" do
      # DSL extension callback pattern (e.g. Spark Dsl.Section after_define):
      # a regular def returns a `quote do ... end` AST that the framework
      # emits into the consumer module at compile time. The eval_quoted
      # inside the quote runs at the consumer's compile time, not at
      # runtime. Sobelow has the same exemption (`# sobelow_skip`).
      code = ~S"""
      defmodule MyApp.Extension do
        def after_define do
          quote do
            module = __MODULE__

            Code.eval_quoted(
              MyApp.Extension.__build__(module),
              [],
              __ENV__
            )
          end
        end
      end
      """

      assert_clean(UnsafeDeserialization, code, file: "lib/my_app/extension.ex")
    end

    test "STILL fires on `Code.eval_string` even in defmacro" do
      # eval_string parses+evals a runtime string. Even in macro context,
      # if the string can flow from external input, RCE. Only eval_quoted
      # in macro is the established compile-time-metaprog pattern.
      code = ~S"""
      defmodule MyApp.M do
        defmacro generate(source) do
          Code.eval_string(source)
        end
      end
      """

      assert_flagged(UnsafeDeserialization, code, file: "lib/my_app/m.ex")
    end
  end

  describe "id/0 and description/0" do
    test "rule id is stable" do
      assert UnsafeDeserialization.id() == "5.50"
    end

    test "description mentions deserialization" do
      assert UnsafeDeserialization.description() =~ "deserialization"
    end
  end
end
