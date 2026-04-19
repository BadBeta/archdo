defmodule Archdo.Rules.Module.SequentialWhereParallelTest do
  use Archdo.RuleCase

  alias Archdo.Rules.Module.SequentialWhereParallel

  describe "Enum.map with I/O callback" do
    test "flags Enum.map with Repo call in callback" do
      code = ~S"""
      defmodule MyApp.BatchProcessor do
        def process_all(ids) do
          Enum.map(ids, fn id ->
            Repo.get!(User, id)
          end)
        end
      end
      """

      diagnostics = assert_flagged(SequentialWhereParallel, code)
      assert [diag] = diagnostics
      assert diag.rule_id == "5.42"
      assert diag.message =~ "Repo.get!"
      assert diag.message =~ "Task.async_stream"
    end

    test "flags Enum.each with HTTP call" do
      code = ~S"""
      defmodule MyApp.Notifier do
        def notify_all(users) do
          Enum.each(users, fn user ->
            HTTPoison.post(user.webhook_url, "event")
          end)
        end
      end
      """

      [diag] = assert_flagged(SequentialWhereParallel, code)
      assert diag.message =~ "HTTPoison.post"
    end

    test "flags Enum.flat_map with File read" do
      code = ~S"""
      defmodule MyApp.FileLoader do
        def load_all(paths) do
          Enum.flat_map(paths, fn path ->
            File.read!(path)
            |> String.split("\\n")
          end)
        end
      end
      """

      [diag] = assert_flagged(SequentialWhereParallel, code)
      assert diag.message =~ "File.read!"
    end

    test "flags Enum.map with function capture to I/O module" do
      code = ~S"""
      defmodule MyApp.Fetcher do
        def fetch_all(urls) do
          Enum.map(urls, &Req.get!/1)
        end
      end
      """

      [diag] = assert_flagged(SequentialWhereParallel, code)
      assert diag.message =~ "Req.get!"
    end
  end

  describe "for comprehension with I/O" do
    test "flags for with Repo call in body" do
      code = ~S"""
      defmodule MyApp.Exporter do
        def export(records) do
          for record <- records do
            Repo.insert!(record)
          end
        end
      end
      """

      [diag] = assert_flagged(SequentialWhereParallel, code)
      assert diag.message =~ "for comprehension"
      assert diag.message =~ "Repo.insert!"
    end
  end

  describe "sequential independent I/O bindings" do
    test "flags sequential independent Repo calls" do
      code = ~S"""
      defmodule MyApp.Dashboard do
        def load(user_id) do
          user = Repo.get!(User, user_id)
          posts = Repo.all(Post)
          comments = Repo.all(Comment)
          {user, posts, comments}
        end
      end
      """

      diagnostics = assert_flagged(SequentialWhereParallel, code)
      assert Enum.any?(diagnostics, &(&1.message =~ "independent I/O calls"))
    end
  end

  describe "clean code — no false positives" do
    test "does not flag Enum.map with pure function" do
      code = ~S"""
      defmodule MyApp.Transform do
        def double_all(numbers) do
          Enum.map(numbers, fn n -> n * 2 end)
        end
      end
      """

      assert_clean(SequentialWhereParallel, code)
    end

    test "does not flag Task.async_stream (already parallel)" do
      code = ~S"""
      defmodule MyApp.Parallel do
        def fetch_all(urls) do
          urls
          |> Task.async_stream(&Req.get!/1)
          |> Enum.map(fn {:ok, result} -> result end)
        end
      end
      """

      assert_clean(SequentialWhereParallel, code)
    end

    test "does not flag test files" do
      code = ~S"""
      defmodule MyApp.BatchTest do
        def helper(ids) do
          Enum.map(ids, fn id -> Repo.get!(User, id) end)
        end
      end
      """

      assert_clean(SequentialWhereParallel, code, file: "test/batch_test.exs")
    end

    test "does not flag Enum.map with string operations" do
      code = ~S"""
      defmodule MyApp.Formatter do
        def format_names(names) do
          Enum.map(names, fn name ->
            name
            |> String.trim()
            |> String.capitalize()
          end)
        end
      end
      """

      assert_clean(SequentialWhereParallel, code)
    end

    test "does not flag sequential dependent bindings" do
      code = ~S"""
      defmodule MyApp.Pipeline do
        def process(id) do
          user = Repo.get!(User, id)
          profile = Repo.get_by!(Profile, user_id: user.id)
          {user, profile}
        end
      end
      """

      # profile depends on user.id — not independent
      # This is tricky — our analysis checks variable refs in args
      # The second call references `user` which is defined by the first
      assert_clean(SequentialWhereParallel, code)
    end
  end
end
