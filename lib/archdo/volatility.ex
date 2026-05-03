defmodule Archdo.Volatility do
  @moduledoc false

  # §§ elixir-planning: §6 — second classifier (after Archdo.Phoenix).
  # Tags each module by the volatility of its outbound dependencies. The
  # ~30 future CE rules consume this via opts[:volatility]; this module
  # owns the policy and the dual-purpose call-site resolution.
  #
  # Per-dependency tags:
  #
  #   :stable                 — narrow surface, long-stable, rare break
  #   :stable_with_test_seam  — framework provides Substitutability already
  #                              (Ecto.Repo + Sandbox, Oban + Oban.Testing)
  #   :volatile               — vendor- or protocol-driven surface drift
  #   :non_deterministic      — testability hazard rather than vendor drift
  #
  # Per-module tags (the result of classify_module/3):
  #
  #   :stable | :volatile | :mixed
  #
  # Module density = (volatile + non_deterministic calls) / total classified
  # calls. :stable_with_test_seam calls don't count — they're framework
  # abstractions handled by CE-15 (Group F).

  alias Archdo.AST

  @type dep_tag :: :stable | :stable_with_test_seam | :volatile | :non_deterministic
  @type tag :: :stable | :volatile | :mixed
  @type call :: {module(), atom(), arity()}

  @type classification :: %{
          tag: tag(),
          density: float(),
          evidence: %{
            volatile_calls: [call()],
            stable_calls: [call()],
            override: nil | :path | :author,
            tag_rationale: %{module() => String.t()}
          }
        }

  @volatile_threshold 0.40
  @stable_threshold 0.05

  # Default per-dependency profile. Project overrides come through
  # `opts[:dependency_volatility]`. Each entry is `{key, tag, rationale}`
  # where key is a module atom OR a regex matched against module strings.
  # Defined as a function (not @attribute) so regex literals can be
  # constructed at call time — module attributes can't hold compiled
  # Regex structs because of the embedded reference.
  defp default_dependency_volatility,
    do: [
      # Stdlib & BEAM (intrinsically stable)
      {:lists, :stable, "OTP stdlib"},
      {:maps, :stable, "OTP stdlib"},
      {:erlang, :stable, "BEAM primitives"},
      {:string, :stable, "OTP stdlib"},
      {Phoenix.PubSub, :stable, "framework primitive"},
      # Standards-implementing libraries (mature)
      {URI, :stable, "RFC 3986"},
      {Base, :stable, "RFC 4648"},
      {:base64, :stable, "RFC 4648"},
      {:crypto, :stable, "NIST FIPS / IETF — standard algorithms"},
      {:zlib, :stable, "RFC 1950/1951"},
      {:public_key, :stable, "X.509 / PKCS"},
      {Jason, :stable, "RFC 8259 (JSON), mature lib"},
      {Decimal, :stable, "IEEE 754, mature lib"},
      {Calendar.ISO, :stable, "ISO 8601"},
      # Stable with framework-provided test seam (Group F territory)
      {Ecto.Repo, :stable_with_test_seam, "Ecto.Adapters.SQL.Sandbox"},
      {Oban, :stable_with_test_seam, "Oban.Testing"},
      # Volatile — vendor or protocol drift
      {Tesla, :volatile, "HTTP middleware ecosystem churn"},
      {Finch, :volatile, "HTTP client"},
      {Req, :volatile, "HTTP client"},
      {HTTPoison, :volatile, "HTTP client"},
      {Plug.Conn, :volatile, "Phoenix surface"},
      {~r/_sdk$/, :volatile, "vendor SDKs"},
      {~r/^Elixir\.ExAws/, :volatile, "AWS API drift"},
      # Non-deterministic — testability concerns
      {File, :non_deterministic, "filesystem"},
      {System, :non_deterministic, "OS coupling"},
      {:rand, :non_deterministic, "randomness"},
      {:os, :non_deterministic, "OS coupling"}
    ]

  # Dual-purpose modules. `:stable_funs` are function/arity references that
  # should be classified :stable even when the rest of the module is
  # non_deterministic. The reverse for `:non_deterministic_funs`.
  @default_dual_purpose %{
    DateTime => %{
      stable_funs: [
        {:from_iso8601, 1},
        {:from_iso8601, 2},
        {:to_iso8601, 1},
        {:to_iso8601, 2},
        {:to_string, 1},
        {:compare, 2}
      ],
      non_deterministic_funs: [{:utc_now, 0}, {:now, 1}]
    },
    :inet => %{
      stable_funs: [
        {:parse_address, 1},
        {:ntoa, 1},
        {:parse_ipv4_address, 1},
        {:parse_ipv6_address, 1}
      ],
      non_deterministic_funs: [
        {:getaddr, 2},
        {:gethostbyname, 1}
      ]
    },
    :calendar => %{
      stable_funs: [
        {:date_to_gregorian_days, 1},
        {:gregorian_days_to_date, 1}
      ],
      non_deterministic_funs: [
        {:local_time, 0},
        {:universal_time, 0}
      ]
    }
  }

  @doc """
  Classify a single file/AST. Returns `%{tag, density, evidence}`.

  Options:

    * `:dependency_volatility` — keyword list of `{key, tag, rationale}` entries
      that augment / override the shipped defaults.
    * `:dual_purpose_modules` — map of `module => %{stable_funs, non_deterministic_funs}`.
    * `:volatile_paths` — list of glob patterns; matching files force `:volatile`.
    * `:stable_paths` — list of glob patterns; matching files force `:stable`.
  """
  @spec classify_module(String.t(), Macro.t(), keyword()) :: classification()
  def classify_module(file, ast, opts \\ []) do
    cond do
      author = author_override(ast) ->
        force(author, :author, density: nil, calls: [], rationale: %{})

      path_override = path_override(file, opts) ->
        force(path_override, :path, density: nil, calls: [], rationale: %{})

      entry_point?(ast) ->
        force(:stable, :entry_point, density: nil, calls: [], rationale: %{})

      true ->
        classify_from_calls(file, ast, opts)
    end
  end

  # Entry-point modules — Mix tasks, Application bootstraps — are the
  # canonical "boundary layer" in OTP-flavored Elixir. Their job is to
  # bridge the outside world: read CLI args, read config, write output,
  # spawn supervised children. Calling File / System / IO directly is
  # not a substitutability hole — pushing those calls behind a
  # behaviour just moves the volatility one module deeper, where the
  # *new* module would be flagged the same way. Mark these stable by
  # design so CE-1 / CE-2 / 4.8 don't fire on them.
  defp entry_point?(ast) do
    AST.contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Mix, :Task]} | _]} -> true
      {:use, _, [{:__aliases__, _, [:Application]} | _]} -> true
      _ -> false
    end)
  end

  @doc "True for `:mixed` classifications; false otherwise."
  @spec mixed?(classification() | %{tag: tag()}) :: boolean()
  def mixed?(%{tag: :mixed}), do: true
  def mixed?(_), do: false

  @doc """
  Resolve a per-file volatility classification, preferring the
  cached `opts[:volatility]` from the runner over a fresh
  `classify_module/2` walk. Used by all CE rules that need a
  per-file volatility tag.
  """
  @spec classification_for(String.t(), Macro.t(), keyword() | term()) :: classification()
  def classification_for(file, ast, opts) when is_list(opts) do
    case Keyword.get(opts, :volatility) do
      nil -> classify_module(file, ast)
      c -> c
    end
  end

  def classification_for(file, ast, _), do: classify_module(file, ast)

  # --- author override (@archdo_volatility) ---

  defp author_override(ast) do
    AST.find_all(ast, fn
      {:@, _, [{:archdo_volatility, _, [_]}]} -> true
      _ -> false
    end)
    |> Enum.find_value(fn
      {:@, _, [{:archdo_volatility, _, [{:__block__, _, [val]}]}]} when is_atom(val) -> val
      {:@, _, [{:archdo_volatility, _, [val]}]} when is_atom(val) -> val
      _ -> nil
    end)
    |> case do
      nil -> nil
      :stable -> :stable
      :volatile -> :volatile
      :mixed -> :mixed
      _ -> nil
    end
  end

  # --- path override ---

  defp path_override(file, opts) do
    cond do
      match_any?(file, Keyword.get(opts, :volatile_paths, [])) -> :volatile
      match_any?(file, Keyword.get(opts, :stable_paths, [])) -> :stable
      true -> nil
    end
  end

  defp match_any?(_file, []), do: false

  defp match_any?(file, patterns) do
    Enum.any?(patterns, fn pattern ->
      regex = pattern |> glob_to_regex() |> Regex.compile!()
      Regex.match?(regex, file)
    end)
  end

  defp glob_to_regex(pattern) do
    pattern
    |> String.replace("**", "@@DOUBLESTAR@@")
    |> String.replace("*", "[^/]*")
    |> String.replace("@@DOUBLESTAR@@", ".*")
    |> then(&("^" <> &1 <> "$"))
  end

  # --- core: classify by call analysis ---

  defp classify_from_calls(_file, ast, opts) do
    profile = build_profile(opts)
    dual_purpose = Map.merge(@default_dual_purpose, Keyword.get(opts, :dual_purpose_modules, %{}))

    classified_calls = collect_classified_calls(ast, profile, dual_purpose)
    {volatile_calls, stable_calls} = split_calls(classified_calls)

    total = length(classified_calls)
    volatile = length(volatile_calls)
    density = if total == 0, do: 0.0, else: volatile / total

    rationale =
      classified_calls
      |> Enum.map(fn {mod, _f, _a, _tag, reason} -> {mod, reason} end)
      |> Map.new()

    %{
      tag: tag_from_density(density),
      density: density,
      evidence: %{
        volatile_calls: Enum.map(volatile_calls, fn {m, f, a, _t, _r} -> {m, f, a} end),
        stable_calls: Enum.map(stable_calls, fn {m, f, a, _t, _r} -> {m, f, a} end),
        override: nil,
        tag_rationale: rationale
      }
    }
  end

  defp tag_from_density(density) when density >= @volatile_threshold, do: :volatile
  defp tag_from_density(density) when density <= @stable_threshold, do: :stable
  defp tag_from_density(_), do: :mixed

  defp force(tag, override, opts) do
    %{
      tag: tag,
      density: opts[:density] || 0.0,
      evidence: %{
        volatile_calls: opts[:calls] || [],
        stable_calls: [],
        override: override,
        tag_rationale: opts[:rationale] || %{}
      }
    }
  end

  defp split_calls(calls) do
    Enum.split_with(calls, fn {_m, _f, _a, tag, _r} ->
      tag in [:volatile, :non_deterministic]
    end)
  end

  # --- profile lookup ---

  defp build_profile(opts) do
    user = Keyword.get(opts, :dependency_volatility, [])
    default_dependency_volatility() ++ user
  end

  defp lookup_profile(profile, mod) do
    Enum.find_value(profile, fn
      {^mod, tag, reason} ->
        {tag, reason}

      {%Regex{} = re, tag, reason} ->
        case Regex.match?(re, Atom.to_string(mod)) do
          true -> {tag, reason}
          false -> nil
        end

      _ ->
        nil
    end)
  end

  # --- AST walk: collect all qualified calls ---

  defp collect_classified_calls(ast, profile, dual_purpose) do
    ast
    |> AST.find_all(&qualified_call?/1)
    |> Enum.flat_map(&extract_call/1)
    |> Enum.flat_map(fn {mod, fun, arity} ->
      case classify_call(mod, fun, arity, profile, dual_purpose) do
        nil -> []
        {tag, reason} -> [{mod, fun, arity, tag, reason}]
      end
    end)
  end

  defp qualified_call?({{:., _, [{:__aliases__, _, _}, _]}, _, _}), do: true
  defp qualified_call?({{:., _, [mod, _]}, _, _}) when is_atom(mod), do: true
  defp qualified_call?({{:., _, [{:__block__, _, [mod]}, _]}, _, _}) when is_atom(mod), do: true
  defp qualified_call?(_), do: false

  defp extract_call({{:., _, [{:__aliases__, _, parts}, fun]}, _, args}) do
    case Enum.all?(parts, &is_atom/1) do
      true -> [{Module.concat(parts), fun, args_arity(args)}]
      false -> []
    end
  end

  defp extract_call({{:., _, [mod, fun]}, _, args}) when is_atom(mod) and is_atom(fun) do
    [{mod, fun, args_arity(args)}]
  end

  # literal_encoder wraps bare-atom Erlang module references like `:rand`
  # as `{:__block__, _, [:rand]}` — unwrap before classifying.
  defp extract_call({{:., _, [{:__block__, _, [mod]}, fun]}, _, args})
       when is_atom(mod) and is_atom(fun) do
    [{mod, fun, args_arity(args)}]
  end

  defp extract_call(_), do: []

  defp args_arity(args) when is_list(args), do: length(args)
  defp args_arity(_), do: 0

  defp classify_call(mod, fun, arity, profile, dual_purpose) do
    case Map.get(dual_purpose, mod) do
      nil ->
        lookup_profile(profile, mod)

      %{stable_funs: stable, non_deterministic_funs: nd} ->
        cond do
          {fun, arity} in stable ->
            {:stable, "dual-purpose #{inspect(mod)}.#{fun}/#{arity}"}

          {fun, arity} in nd ->
            {:non_deterministic, "dual-purpose #{inspect(mod)}.#{fun}/#{arity}"}

          true ->
            lookup_profile(profile, mod)
        end
    end
  end
end
