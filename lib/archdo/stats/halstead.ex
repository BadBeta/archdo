defmodule Archdo.Stats.Halstead do
  @moduledoc """
  Halstead software-science metrics for Elixir AST. Computes
  vocabulary, length, volume, difficulty, and effort over a function
  body or an entire module's collected function bodies. Pure function
  over AST — no side effects, no I/O, no Repo. Public API consumed by
  `Archdo.Stats` and surfaced in `mix archdo --metrics`.

  Operators are AST nodes whose head atom appears in `@operator_atoms`
  (binary/unary operators + control-flow keywords + clause arrow).
  Operands are leaves: literals, variable references, called function
  names, and module aliases. Function calls themselves are NOT counted
  as operators — the called name appears as an operand. This is a
  deliberate Elixir-specific calibration that keeps the metric
  proportional to structural complexity rather than scaling with every
  helper invocation.

  Halstead metric definitions:
  - vocabulary  = distinct_operators + distinct_operands
  - length      = total_operators + total_operands
  - volume      = length × log₂(vocabulary)
  - difficulty  = (distinct_operators / 2) × (total_operands / distinct_operands)
  - effort      = volume × difficulty
  """

  Module.register_attribute(__MODULE__, :archdo_volatility, persist: true)
  @archdo_volatility :stable

  # §§ elixir-implementing: §1 #23 — SSOT for what counts as a Halstead
  # operator in Elixir AST. Single source; all walker dispatch matches
  # against this list. Adding a new operator means editing one line.
  @operator_atoms ~w(
    + - * / ** ==  != < <= > >= === !== =
    |> <- <> ++ -- && || and or not ! | :: ..
    case cond if unless with for try receive fn ->
  )a

  @type result :: %{
          vocabulary: non_neg_integer(),
          length: non_neg_integer(),
          volume: float(),
          difficulty: float(),
          effort: float(),
          distinct_operators: non_neg_integer(),
          distinct_operands: non_neg_integer(),
          total_operators: non_neg_integer(),
          total_operands: non_neg_integer()
        }

  @empty %{
    distinct_operators: MapSet.new(),
    distinct_operands: MapSet.new(),
    total_operators: 0,
    total_operands: 0
  }

  @doc """
  Compute Halstead metrics for an AST. Accepts either a module AST
  (any `defmodule ... do ... end` shape) or a single function body.

  When the AST contains `def`/`defp`/`defmacro`/`defmacrop` forms,
  Halstead is computed over the union of their bodies (function heads
  and the `def` keyword itself are excluded). When no function form is
  found, the AST is treated as a single body.
  """
  @spec analyze(Macro.t()) :: result()
  def analyze(ast) do
    bodies = collect_bodies(ast)
    measure(bodies, ast)
  end

  @doc """
  Compute Halstead metrics for a single function. Accepts either a
  raw body AST (whatever appears between `do:` and `end`) or a full
  `def`/`defp`/`defmacro`/`defmacrop` form (in which case the body is
  extracted automatically).
  """
  @spec analyze_function(Macro.t()) :: result()
  def analyze_function({def_kw, _, [_head, [{:do, body} | _]]})
      when def_kw in [:def, :defp, :defmacro, :defmacrop] do
    finalize(walk(body, @empty))
  end

  def analyze_function(body), do: finalize(walk(body, @empty))

  # §§ elixir-implementing: §2.1 — multi-clause head dispatches on the
  # presence of function bodies (no if/else); each clause names the
  # case, the catch-all treats the AST as a single body.
  defp measure([], single_body), do: finalize(walk(single_body, @empty))

  defp measure(bodies, _ast),
    do: finalize(Enum.reduce(bodies, @empty, &walk/2))

  # Collect every function body found anywhere in the AST. Walks via
  # Macro.prewalk to handle nested modules. Order doesn't matter — we
  # union all bodies into one Halstead computation.
  defp collect_bodies(ast) do
    {_, bodies} = Macro.prewalk(ast, [], &collect_body/2)
    bodies
  end

  defp collect_body(
         {def_kw, _, [_head, [{:do, body} | _]]} = node,
         acc
       )
       when def_kw in [:def, :defp, :defmacro, :defmacrop] do
    {node, [body | acc]}
  end

  defp collect_body(node, acc), do: {node, acc}

  # --- Walker ---
  #
  # Each clause either: (a) counts an operator and recurses into args,
  # (b) counts an operand and stops, or (c) recurses into a container.

  # Operator node: a 3-tuple whose head atom is in @operator_atoms.
  # §§ elixir-implementing: §2.1 — pattern match on shape with a guard
  # narrowing on @operator_atoms; alternatives (case + guard, body
  # checks) lose compile-time exhaustiveness on the operator list.
  defp walk({op, _, args}, acc) when op in @operator_atoms and is_list(args) do
    walk_list(args, bump_operator(acc, op))
  end

  # Variable reference: 3-tuple with atom name and atom/nil context,
  # empty/nil third element semantics. The third element being an atom
  # (the context module of the binding) distinguishes a variable from
  # a zero-arity call.
  defp walk({name, _, ctx}, acc) when is_atom(name) and is_atom(ctx) do
    bump_operand(acc, {:var, name})
  end

  # Remote function call: `Mod.fun(args)` → AST `{{:., _, [mod, fun]}, _, args}`.
  # The dot itself is structural; the fun-name is the called identity
  # (operand) and we recurse into the module ref + args.
  defp walk({{:., _, [mod, fun]}, _, args}, acc) when is_atom(fun) and is_list(args) do
    acc1 = bump_operand(acc, {:fun, fun})
    acc2 = walk(mod, acc1)
    walk_list(args, acc2)
  end

  # Local function call: 3-tuple, atom name, list args, name not in
  # operator atoms (handled by the operator clause above). Examples:
  # `g()`, `helper(x, y)`. The called name is an operand; arguments
  # recursed.
  defp walk({name, _, args}, acc)
       when is_atom(name) and is_list(args) do
    walk_list(args, bump_operand(acc, {:fun, name}))
  end

  # Module alias: `Foo.Bar.Baz` → `{:__aliases__, _, [:Foo, :Bar, :Baz]}`.
  # Treat the joined name as a single operand identity.
  defp walk({:__aliases__, _, parts}, acc) do
    bump_operand(acc, {:mod, parts})
  end

  # Containers — recurse without counting the container itself.
  defp walk({a, b}, acc), do: walk(b, walk(a, acc))
  defp walk(list, acc) when is_list(list), do: walk_list(list, acc)

  # Literals — operands with their value as identity.
  defp walk(int, acc) when is_integer(int), do: bump_operand(acc, {:int, int})
  defp walk(flt, acc) when is_float(flt), do: bump_operand(acc, {:flt, flt})
  defp walk(str, acc) when is_binary(str), do: bump_operand(acc, {:str, str})
  defp walk(atom, acc) when is_atom(atom), do: bump_operand(acc, {:atom, atom})

  # Anything else (e.g., bitstring literals captured as nodes) — skip.
  defp walk(_, acc), do: acc

  defp walk_list(list, acc), do: Enum.reduce(list, acc, &walk/2)

  defp bump_operator(acc, op) do
    %{
      acc
      | distinct_operators: MapSet.put(acc.distinct_operators, op),
        total_operators: acc.total_operators + 1
    }
  end

  defp bump_operand(acc, identity) do
    %{
      acc
      | distinct_operands: MapSet.put(acc.distinct_operands, identity),
        total_operands: acc.total_operands + 1
    }
  end

  # --- Finalization ---

  defp finalize(%{
         distinct_operators: ops_set,
         distinct_operands: opnds_set,
         total_operators: t_op,
         total_operands: t_opnd
       }) do
    distinct_ops = MapSet.size(ops_set)
    distinct_opnds = MapSet.size(opnds_set)
    vocabulary = distinct_ops + distinct_opnds
    length_ = t_op + t_opnd
    volume = compute_volume(length_, vocabulary)
    difficulty = compute_difficulty(distinct_ops, t_opnd, distinct_opnds)
    effort = volume * difficulty

    %{
      vocabulary: vocabulary,
      length: length_,
      volume: volume,
      difficulty: difficulty,
      effort: effort,
      distinct_operators: distinct_ops,
      distinct_operands: distinct_opnds,
      total_operators: t_op,
      total_operands: t_opnd
    }
  end

  # §§ elixir-implementing: §2.1 — multi-clause on the degenerate
  # vocabulary=0 case (empty AST). Avoids guarding inside the body and
  # keeps the formula expressible as a one-liner.
  defp compute_volume(_length, 0), do: 0.0
  defp compute_volume(length_, vocabulary), do: length_ * :math.log2(vocabulary)

  defp compute_difficulty(_d_ops, _t_opnd, 0), do: 0.0

  defp compute_difficulty(d_ops, t_opnd, d_opnd),
    do: d_ops / 2 * (t_opnd / d_opnd)
end
