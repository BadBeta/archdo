defmodule Archdo.Rules.OTP.MissingTerminateTest do
  use Archdo.RuleCase

  alias Archdo.Rules.OTP.MissingTerminate

  test "flags GenServer with File.open but no terminate" do
    code = ~S"""
    defmodule MyApp.FileWorker do
      use GenServer

      def init(path) do
        {:ok, file} = File.open(path, [:write])
        {:ok, %{file: file}}
      end
    end
    """

    assert_flagged(MissingTerminate, code)
  end

  test "allows GenServer with File.open and terminate" do
    code = ~S"""
    defmodule MyApp.FileWorker do
      use GenServer

      def init(path) do
        {:ok, file} = File.open(path, [:write])
        {:ok, %{file: file}}
      end

      def terminate(_reason, %{file: file}) do
        File.close(file)
      end
    end
    """

    assert_clean(MissingTerminate, code)
  end

  test "ignores non-GenServer modules with File.open" do
    code = ~S"""
    defmodule MyApp.Utils do
      def read_file(path) do
        {:ok, file} = File.open(path, [:read])
        data = IO.read(file, :all)
        File.close(file)
        data
      end
    end
    """

    assert_clean(MissingTerminate, code)
  end
end
