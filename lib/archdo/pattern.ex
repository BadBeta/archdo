defmodule Archdo.Pattern do
  @moduledoc false

  # Glob-style pattern matching for module names, with set algebra on matches.
  #
  # Pattern syntax:
  #   "MyApp.Accounts"         — exact match
  #   "MyApp.*"                — one level of nesting
  #   "MyApp.**"               — any depth of nesting under MyApp
  #   "MyApp.**.*Repo"         — modules ending in Repo at any depth
  #   "**.Schema"              — any module ending in Schema
  #
  # This is more flexible than raw regex and aligns with how ArchTest and
  # clean_mixer express module selection, making Archdo configs more familiar.

  @type pattern :: String.t()
  @type module_name :: String.t()

  @doc """
  Check if a module name matches a glob pattern.

  Examples:
      iex> Archdo.Pattern.matches?("MyApp.Accounts.User", "MyApp.**")
      true

      iex> Archdo.Pattern.matches?("MyApp.Accounts.User", "MyApp.*")
      false

      iex> Archdo.Pattern.matches?("MyApp.Accounts.UserRepo", "**.*Repo")
      true
  """
  @spec matches?(module_name() | module(), pattern()) :: boolean()
  def matches?(module_name, pattern) when is_atom(module_name) do
    matches?(normalize(module_name), pattern)
  end

  def matches?(module_name, pattern) when is_binary(module_name) and is_binary(pattern) do
    regex = compile(pattern)
    Regex.match?(regex, normalize(module_name))
  end

  @doc """
  Normalize a module name (atom or string) to a string without the "Elixir." prefix.
  """
  @spec normalize(module() | String.t()) :: String.t()
  def normalize(mod) when is_atom(mod) do
    mod |> Atom.to_string() |> normalize()
  end

  def normalize(mod) when is_binary(mod) do
    String.replace_leading(mod, "Elixir.", "")
  end

  @doc """
  Filter a list of module names by a glob pattern.
  """
  @spec filter([module_name()], pattern()) :: [module_name()]
  def filter(modules, pattern) do
    regex = compile(pattern)
    Enum.filter(modules, fn m -> Regex.match?(regex, normalize(m)) end)
  end

  @doc """
  Set algebra: union of two module sets from different patterns.
  """
  @spec union([module_name()], [module_name()]) :: [module_name()]
  def union(set_a, set_b), do: Enum.uniq(set_a ++ set_b)

  @doc """
  Set algebra: intersection of two module sets.
  """
  @spec intersection([module_name()], [module_name()]) :: [module_name()]
  def intersection(set_a, set_b) do
    b_set = MapSet.new(set_b)
    Enum.filter(set_a, &MapSet.member?(b_set, &1))
  end

  @doc """
  Set algebra: difference (modules in A but not in B).
  """
  @spec difference([module_name()], [module_name()]) :: [module_name()]
  def difference(set_a, set_b) do
    b_set = MapSet.new(set_b)
    Enum.reject(set_a, &MapSet.member?(b_set, &1))
  end

  @doc """
  Compile a glob pattern to a regex.

  Grammar:
    ** — match any sequence of characters including dots (any nesting depth)
    *  — match any sequence of characters except dots (one segment)
    .  — literal dot (segment separator)
    other chars — literal

  The resulting regex is anchored (^...$).
  """
  @spec compile(pattern()) :: Regex.t()
  def compile(pattern) when is_binary(pattern) do
    regex_source =
      pattern
      |> tokenize()
      |> Enum.map(&token_to_regex/1)
      |> Enum.join()

    Regex.compile!("^" <> regex_source <> "$")
  end

  # Tokenize into literal and glob segments
  defp tokenize(pattern) do
    pattern
    |> String.to_charlist()
    |> do_tokenize([], [])
  end

  defp do_tokenize([], [], tokens), do: Enum.reverse(tokens)
  defp do_tokenize([], buf, tokens), do: Enum.reverse([{:lit, Enum.reverse(buf) |> List.to_string()} | tokens])

  defp do_tokenize([?*, ?* | rest], buf, tokens) do
    tokens =
      case buf do
        [] -> tokens
        _ -> [{:lit, Enum.reverse(buf) |> List.to_string()} | tokens]
      end

    do_tokenize(rest, [], [:double_star | tokens])
  end

  defp do_tokenize([?* | rest], buf, tokens) do
    tokens =
      case buf do
        [] -> tokens
        _ -> [{:lit, Enum.reverse(buf) |> List.to_string()} | tokens]
      end

    do_tokenize(rest, [], [:star | tokens])
  end

  defp do_tokenize([c | rest], buf, tokens) do
    do_tokenize(rest, [c | buf], tokens)
  end

  defp token_to_regex({:lit, str}), do: Regex.escape(str)
  # Single * = any chars except dot
  defp token_to_regex(:star), do: "[^.]*"
  # ** = any chars including dots
  defp token_to_regex(:double_star), do: ".*"
end
