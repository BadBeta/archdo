defmodule Archdo.Rules.Module.RaiseInNonBangTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.RaiseInNonBang

  describe "analyze/3" do
    test "flags non-bang function that raises" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          if input == "" do
            raise ArgumentError, "input cannot be empty"
          end

          do_parse(input)
        end
      end
      """

      diags = assert_flagged(RaiseInNonBang, code)
      diag = hd(diags)
      assert diag.rule_id == "6.10"
      assert diag.severity == :warning
    end

    test "allows bang function that raises" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse!(input) do
          if input == "" do
            raise ArgumentError, "input cannot be empty"
          end

          do_parse(input)
        end
      end
      """

      assert_clean(RaiseInNonBang, code)
    end

    test "allows non-bang function without raise" do
      code = ~S"""
      defmodule MyApp.Parser do
        def parse(input) do
          case do_parse(input) do
            {:ok, result} -> {:ok, result}
            {:error, reason} -> {:error, reason}
          end
        end
      end
      """

      assert_clean(RaiseInNonBang, code)
    end

    test "allows init/1 with raise (setup context)" do
      code = ~S"""
      defmodule MyApp.Worker do
        def init(opts) do
          unless Keyword.has_key?(opts, :name) do
            raise ArgumentError, "missing required :name option"
          end

          {:ok, opts}
        end
      end
      """

      assert_clean(RaiseInNonBang, code)
    end

    test "does not flag @impl true callbacks (framework-defined contract)" do
      # mount/3, handle_event/3 etc. have fixed names defined by Phoenix
      # LiveView; they CAN'T be renamed with `!`. Raising on misconfiguration
      # is documented framework behaviour. (BUG-8 from phoenix_live_dashboard.)
      code = ~S"""
      defmodule MyAppWeb.PageLive do
        use Phoenix.LiveView

        @impl true
        def mount(%{"id" => id}, _session, socket) do
          if id == nil do
            raise "missing id"
          else
            {:ok, assign(socket, id: id)}
          end
        end
      end
      """

      assert_clean(RaiseInNonBang, code)
    end

    test "does not flag @impl SomeBehaviour callbacks" do
      code = ~S"""
      defmodule MyApp.Worker do
        @behaviour MyApp.WorkerBehaviour

        @impl MyApp.WorkerBehaviour
        def perform(args) do
          unless args, do: raise("args required")
        end
      end
      """

      assert_clean(RaiseInNonBang, code)
    end

    test "does not flag def inside defimpl (protocol-fixed contract)" do
      # `defimpl Protocol, for: Type do def write(...) end` — the function name
      # is fixed by the protocol, can't be renamed `write!`. The "raise not
      # implemented" pattern is the canonical signal for partial protocol
      # implementations. (BUG-9 from Livebook.)
      code = ~S"""
      defmodule MyApp.ReadOnly do
        defstruct [:path]
      end

      defimpl MyApp.FileSystem, for: MyApp.ReadOnly do
        def read(fs, path), do: File.read(Path.join(fs.path, path))
        def write(_fs, _path, _content), do: raise("not implemented")
        def delete(_fs, _path), do: raise("not implemented")
      end
      """

      assert_clean(RaiseInNonBang, code)
    end

    test "still flags non-callback function that raises" do
      code = ~S"""
      defmodule MyApp.Helper do
        def parse(input) do
          raise "bad input"
        end
      end
      """

      diags = assert_flagged(RaiseInNonBang, code)
      assert hd(diags).rule_id == "6.10"
    end

    test "skips private functions" do
      code = ~S"""
      defmodule MyApp.Internal do
        defp validate(data) do
          raise "bad data"
        end
      end
      """

      assert_clean(RaiseInNonBang, code)
    end
  end
end
