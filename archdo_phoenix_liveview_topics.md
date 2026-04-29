# Archdo — Phoenix / LiveView Coverage Topics

Areas where Archdo currently has **no rules** (or thin rules) for Phoenix and
Phoenix LiveView idioms. Each topic notes the kind of analysis, the kinds of
bugs it would catch, and a sketch of detection.

Surfaced from field tests against:
- **PhiaUI** (charlenopires/PhiaUI) — UI component library, ~127k LoC
- **hexpm** (hexpm/hexpm) — production Phoenix app, ~34k LoC

---

## 1. Plug pipeline composition

Archdo currently doesn't analyse `plug` calls in routers, controllers, or
endpoint pipelines. Phoenix apps live and die by pipeline correctness.

### Topics

| Topic | What it would catch |
|---|---|
| **Auth-then-authz ordering** | `plug :authorize` before `plug :authenticate` — authorization runs without a user |
| **Missing CSRF on `pipe_through :browser`** | A browser pipeline that skipped `:protect_from_forgery` |
| **Missing rate limit on public endpoints** | API pipeline without `PlugAttack` or equivalent |
| **Plug ordering: parsers before session** | `Plug.Parsers` after `:fetch_session` (no body for session-derived params) |
| **Duplicate plugs in pipeline** | Same plug listed twice (often left after refactor) |
| **`plug :anything` in a controller after `def action/2`** | Plug declarations must precede actions |
| **Public action without `plug :authorize`** | A controller has 5 plugged actions and 1 un-plugged — likely an oversight |

### Detection sketch
- Walk `defmodule MyAppWeb.Router` → find `pipeline :name do ... end` blocks → list `plug` calls in order.
- For controllers: collect `plug` declarations + their `:when action in [...]` constraints; cross-check action coverage.
- Maintain a registry of "security-relevant" plug names (`:protect_from_forgery`, `:require_authenticated_user`, etc.) and assert presence on relevant pipelines.

---

## 2. LiveView lifecycle and async hygiene

Phoenix LiveView has 12 anti-patterns called out in the `phoenix-liveview`
skill. Archdo covers 0 of them today.

### Topics (mapped to skill's anti-patterns)

| Topic | What it would catch |
|---|---|
| **`mount/3` without `connected?` guard for PubSub** | `Phoenix.PubSub.subscribe(...)` in mount without `if connected?(socket)` — subscribes twice (HTTP + WS) |
| **Stream with missing `phx-update="stream"` or missing `id`** | The container or the items lack the required attrs — silent reverts to bulk re-render |
| **Large list in `assign` instead of `stream`** | `assign(socket, :items, Repo.all(Item))` — memory grows per LiveView process |
| **Blocking call in `handle_event/3`** | `HTTPClient.get!(url)` in handler — blocks the socket process |
| **Deprecated `live_redirect/2` / `live_patch/2`** | Should be `push_navigate/2` / `push_patch/2` |
| **`Process.sleep` in tests** | Should be `assert_receive` or `render_async` |
| **Form access via `@changeset` directly** | Should use `<.input field={@form[:field]}>` |
| **`<.form let={f}>`** (deprecated) | Should be `for={@form}` form variant |
| **`phx-update="append"` / `"prepend"`** (deprecated) | Replace with `stream/4` |
| **LiveComponent without `id`** | Required; without it, updates conflate |
| **`Task.async` capturing socket assigns** | Closure copies whole assigns into spawned process |
| **Trusting client-submitted IDs** | `handle_event("delete", %{"id" => id}, _)` deletes by raw id without authz check |

### Detection sketch
- LiveView module = file in `_web/live/` OR module that calls `use Phoenix.LiveView` / `use MyAppWeb, :live_view`.
- For each, walk callbacks: `mount/3`, `handle_event/3`, `handle_info/2`, `handle_async/3`.
- Pattern-match on the bad shapes; many are syntactic (one-line patterns).

---

## 3. `live_session`, `on_mount`, and authentication scopes

These are how multi-tenant LiveView apps gate auth. Archdo has nothing here.

### Topics

| Topic | What it would catch |
|---|---|
| **LiveView outside any `live_session`** | A `live "/admin", AdminLive` not in a `live_session` block — `on_mount` hooks won't run |
| **Tenant-required LiveView in user-only `live_session`** | Tenant-scoped routes inside the wrong `live_session` |
| **`on_mount` hook missing `assign_new`** | Re-fetches user on every `push_patch` |
| **LiveView reaching into `socket.assigns.current_user` without an `on_mount` guarantee** | Crashes on unauthenticated paths |
| **Two `live_session`s with overlapping route prefixes** | First match wins — the second is dead |

### Detection sketch
- Parse `MyAppWeb.Router` AST: find every `live_session :name, on_mount: [...]` block and the `live` declarations inside.
- Cross-check each LiveView module's body for `socket.assigns.current_user` references and verify the route is in a session that mounts user.

---

## 4. N+1 query risk

Common LiveView footgun: render assigns access an Ecto association without a
preload. Each row triggers a query.

### Topics

| Topic | What it would catch |
|---|---|
| **Association access in render without preload in mount** | `<%= @user.posts %>` where mount doesn't `preload(:posts)` |
| **Stream member with virtual association** | `<:row :let={device}>{device.cluster.name}</:row>` where `cluster` was never preloaded |
| **`Enum.map(records, & &1.assoc)` in a context** | If `assoc` is not preloaded, this is an N-query loop |
| **`Ecto.assoc/2` inside `Enum.map`** | Per-row sub-query |

### Detection sketch
- Hard. Requires associating LiveView assigns with their Ecto schema fields and walking templates for `.assoc` access. Probably only feasible with `--compiled` analysis (beam metadata gives schema → field → association maps).
- Cheaper proxy: flag any `Enum.map(records, fn r -> r.assoc end)` where the outer call site isn't preceded by a visible `preload`.

---

## 5. Migration safety

`priv/repo/migrations/` files have their own anti-pattern set. Archdo currently
treats them as ordinary modules.

### Topics

| Topic | What it would catch |
|---|---|
| **`add_column` with `null: false` on existing table without backfill** | Migration locks the table while populating |
| **Raw SQL DDL without `disable_ddl_transaction`** | Long DDL holds AccessExclusiveLock |
| **`create index` without `concurrently: true` on Postgres** | Locks writes during build |
| **`drop_if_exists table(:x)`** with foreign keys still pointing in | Cascades or errors |
| **Missing `down` clause** in non-trivial migration | Can't roll back |
| **Migration that calls into application context modules** | App code can change between deploy and migration run — context drift |
| **Two migrations with the same timestamp prefix** | Mix sometimes runs them in undefined order |
| **`change/0` doing destructive work in `up` direction without `up`/`down` split** | Auto-revert breaks |

### Detection sketch
- File path filter: `priv/repo/migrations/*.exs`.
- AST patterns are well-known and stable.

---

## 6. Phoenix routes / controllers (beyond 1.15)

| Topic | What it would catch |
|---|---|
| **Verified routes (`~p`) used outside `Phoenix.VerifiedRoutes` scope** | Compile error masquerading as runtime |
| **`get/post/put` defined twice for the same path with same controller** | Latter overrides; usually a refactor leftover |
| **`scope` blocks that don't `pipe_through` a pipeline** | All requests bypass plugs |
| **Controller action missing `render/3` or response** | Falls through to default; surprising at runtime |
| **`action_fallback` declared but `with` never used** | Fallback is dead |

---

## 7. PubSub / Presence

| Topic | What it would catch |
|---|---|
| **`Phoenix.PubSub.broadcast` without a matching `subscribe` anywhere** | Send-into-the-void |
| **`subscribe(topic)` where topic uses `String.to_atom(user_input)`** | Atom-table risk |
| **`Presence.track` without corresponding `presence_diff` handler** | Half-implemented presence |
| **Custom Presence without `fetch/2` for bulk loading** | N+1 risk on join |

---

## 8. Forms and changesets

| Topic | What it would catch |
|---|---|
| **Changeset built without calling `cast/4`** | Validations run on raw struct values |
| **`unique_constraint/3` declared without a matching DB index** | Race condition allows dupes |
| **Form submitted to controller without `action_fallback` and the action returns `{:error, changeset}`** | 500 response |
| **`<.input field={@form[:x]}>` for a field not in the changeset** | Silent omission |

### Detection sketch
- For `unique_constraint`: cross-reference with migration files (`create unique_index`).
- For changeset → form field consistency: parse the changeset's `cast/4` field list, compare with `<.input>` field references in templates.

---

## 9. HEEx template hygiene

| Topic | What it would catch |
|---|---|
| **`<%= @assign %>` (deprecated `=` form)** | Should be `{@assign}` |
| **`raw/1` on user input** | XSS vector |
| **Unescaped attribute interpolation** | `style="color: <%= @color %>"` without sanitization |
| **`<.live_component>` without `id`** | Required; warns at runtime, not compile time |
| **`phx-click` on a non-clickable element without ARIA** | Accessibility |
| **Component called with attributes that aren't declared via `attr/3`** | Silent ignore |

---

## 10. Mailer / Bamboo / Swoosh

| Topic | What it would catch |
|---|---|
| **`Mailer.deliver/1` without `from/2`** | Bounces or rejects |
| **Email rendered with user-supplied HTML body via `raw/1`** | Phishing-template injection |
| **Mailer module without behaviour seam (`@behaviour`)** | Can't swap in test |

---

## 11. Multi-step `Repo.transaction` / `Multi`

| Topic | What it would catch |
|---|---|
| **`Repo.transaction(fn ... end)` with multi-step DB writes** | Should be `Ecto.Multi` for atomicity reasoning |
| **`Multi.run` with a function that has side effects (HTTP, mailer)** | Side effects don't roll back when DB does |
| **`Repo.transact/2` (Ecto 3.12+) vs `Repo.transaction/1,2`** | Use the new typed API |

---

## 12. Phoenix.Token and signed/encrypted state

| Topic | What it would catch |
|---|---|
| **`Phoenix.Token.sign/3` without `max_age`** | Tokens valid forever |
| **Token verified without checking `:max_age` outcome** | Expired tokens accepted |
| **Token used as both auth and CSRF** | Replay window |

---

## Priority ranking for adding rules

If picking which topic to implement first, my ranking by impact × tractability:

1. **§2 LiveView lifecycle & async** — direct mapping to a published anti-pattern catalog (the skill); detection is mostly pattern-match on syntactic shapes; high false-positive fix value.
2. **§5 Migration safety** — small file count, well-known patterns, clear severity (production downtime).
3. **§1 Plug pipelines** — high impact for security; AST is local to router.
4. **§9 HEEx hygiene** — overlaps with the dead-code work that already touches HEEx scanning.
5. **§3 `live_session` scopes** — requires router parsing; high value for multi-tenant.
6. **§8 Forms / changeset / migration cross-ref** — needs cross-file analysis; defer to `--compiled` mode.
7. **§4 N+1** — hardest; needs schema → assoc mapping. Lowest tractability.

---

## Cross-cutting: Phoenix-aware file classification

Several rules already mis-fire because they don't recognize Phoenix file shapes:
- `lib/my_app_web/components/*.ex` — LiveView function components
- `lib/my_app_web/live/*.ex` — LiveView modules
- `lib/my_app_web/controllers/*.ex` — Phoenix controllers
- `lib/my_app_web/router.ex` — router
- `priv/repo/migrations/*.exs` — Ecto migrations
- `test/my_app_web/live/*_test.exs` — LiveView tests

Adding a `Phoenix.classify_file/1` helper that returns `:component | :live_view | :controller | :router | :migration | :live_test | :other` would let many existing rules carve out Phoenix-specific behaviour cleanly. Could replace ad-hoc `String.contains?(file, "_web/")` checks scattered across rules.

---

## Cross-file template scanning (added 2026-04-29 from phoenix_live_dashboard)

Several Phoenix idioms move code OUT of the `.ex` file:

| Directive | What it does | What Archdo can't see |
|---|---|---|
| `embed_templates "path/*"` | Compiles all matching `.heex`/`.eex` files into the module as function components | References inside the templates to functions in the embedding module — flagged as dead (BUG-7) |
| `<.live_component module={Foo} />` in HEEx | Calls `Foo.update/2` and `Foo.handle_event/3` | The `update`/`handle_event` callbacks may look unused if `update` is overridden but the explicit `update/2` clause isn't recognized as a behaviour callback |
| `pipe_through: :pipeline_name` in router scopes | Reference to a pipeline | Cross-pipeline reasoning — does this scope have auth, CSRF? |
| `live_render(@socket, MyLive, ...)` in HEEx | Mounts a child LiveView | Lifecycle and assigns flow into the child |
| Phoenix.Token.sign / verify across modules | Asymmetric flow (one signs, another verifies) | The pair must agree on `max_age` etc. |

**Tooling implication:** Archdo currently treats one `.ex` file as the full unit of analysis (per-rule analyze/3) plus optional whole-project asts (analyze_project/1). For Phoenix it needs a third primitive: **module-with-its-templates** — given a module that uses `embed_templates`, resolve the glob and parse those .heex files alongside the module's own AST. The same primitive serves at least 5 rules (dead-private, undefined-function-in-template, missing-attr, etc.).

## Framework-callback awareness (added 2026-04-29)

Several rules need to know "this function name is a framework callback I can't rename":

| Function family | Framework | Rules currently mis-firing |
|---|---|---|
| `mount/3`, `handle_event/3`, `handle_info/2`, `handle_async/3`, `render/1`, `update/2`, `terminate/2` | Phoenix LiveView | 6.10 (non-bang raises), 1.27 (large handle_event) — both should treat these as fixed-name |
| `init/1`, `handle_call/3`, `handle_cast/2`, `handle_info/2`, `handle_continue/2`, `terminate/2` | GenServer | 6.10 |
| `cast/2`, `dump/1`, `load/1`, `embed_as/1`, `equal?/2` | Ecto.Type | 6.10 |
| `__options__/1`, `__using__/1`, `__before_compile__/1` | Phoenix/Elixir macros | 6.10 |
| `child_spec/1`, `start_link/1` | Supervision | 6.10 sometimes (raise is normal for misconfig) |

**Cleanest implementation:** when extracting functions, also capture the immediately-preceding `@impl ...` annotation (if any). Pass that to the rule. Rule 6.10 (and others) then treats `@impl`-annotated functions as having a framework-defined contract — raising on bad input is the documented behaviour, naming is fixed.

## Production-AST quirks (added 2026-04-29 round 2 from phoenix_live_dashboard)

The production parser (`AST.parse_file/1`) uses `token_metadata: true` AND
`literal_encoder: &{:ok, {:__block__, &2, [&1]}}`. This shifts AST shapes in
non-obvious ways. Rules that hand-walk the AST need to handle BOTH forms:

| Construct | Code.string_to_quoted (no encoder) | parse_file/1 (production) |
|---|---|---|
| `[do: body]` keyword | `[{:do, body}]` | `[{{:__block__, _, [:do]}, body}]` |
| Literal `false` in `@impl false` | `[false]` | `[{:__block__, _, [false]}]` |
| String literal `"foo"` | `"foo"` | `{:__block__, _, ["foo"]}` |
| Integer arity in `&fn/2` | `2` | `{:__block__, _, [2]}` |
| Atom literal `:ok` | `:ok` | `{:__block__, _, [:ok]}` |

**Concrete impact:** BUG-1 (Rule 3.1 wrong function name on guarded clauses),
BUG-2/3 (rule false positives from over-broad detectors), BUG-5 (multiple
top-level defmodules per file — common Phoenix/Ecto pattern with a tiny
exception module beside the main module), BUG-8 (`extract_module_body/1` not
handling wrapped `:do` keyword). Each was a missing branch for the wrapped form.

**Fix pattern:** wherever a rule pattern-matches an AST literal, add a
parallel clause for `{:__block__, _, [literal]}`. Or — preferred — extract
helpers in `AST` module: `unwrap_literal/1`, `do_body/1`, etc., and use them
everywhere.

## Multiple modules per file (added 2026-04-29 round 2)

Phoenix and Ecto idioms commonly put 2-4 modules in one file:
- `defmodule MyLive.NotFound do defexception ... end` next to the main LiveView
- Ecto schemas with their changeset module beside
- `defmodule Inner do ... end` for a private helper namespace
- Multiple `defimpl` blocks for the same protocol, different types

**Rules that need to be scope-aware:**
- 6.54 Shadowed clause — fixed in BUG-5
- 6.10 Non-bang raises — needed a multi-defmodule walker for `@impl` extraction (fixed in BUG-8)
- 4.x boundary rules (context cohesion, etc.) — still need verification
- 6.4 Module file too long — currently uses raw line count; may want to know per-defmodule sizes

**Suggested helper:** `AST.collect_module_bodies(ast)` — returns `[{module_alias, body, meta}]` for every defmodule in the AST. Reusable by all rules that need per-module scope.

## Macro bodies as call sites (added 2026-04-29 round 2)

`defmacro`/`defmacrop` bodies can call functions defined in the same module.
Without scanning macro bodies, helpers used only from a macro look dead.
Found on phoenix_live_dashboard: `expand_alias/2` called from `defmacro
live_dashboard`. Generalizes — any rule that walks "function bodies" should
include macro bodies, or have an explicit reason not to.

**Affected rules:**
- 6.34 Dead private — fixed in BUG-7 round 2
- Any future rule that asks "does this private function get called?"

## HEEx attribute interpolations (added 2026-04-29 round 2)

The `<.tag attr={Elixir code}>` form embeds real Elixir AST inside HEEx text.
For external `.heex` files (read as raw text by Archdo), the interpolations
appear as text and need regex extraction. The patterns:

| Form | Regex | Example |
|---|---|---|
| `<.fn ...>` | `<\.([a-z_]\w*)` | `<.live_table>` |
| `<.fn />` | (same) | `<.footer />` |
| `&fn/N` capture | `&([a-z_]\w*)\/\d+` | `row_fetcher={&fetch_applications/2}` |
| `fn(args)` call | `\b([a-z_]\w*)\(` | `<%= csp_nonce(@conn, :script) %>` |

For inline `~H` sigils in `.ex` files, the AST already separates code from
text; the better approach is to walk the interpolation slots as real Elixir AST
(reusing `collect_calls_in_body/2`). Not yet implemented — rule 6.34 currently
flattens to text and regex-extracts. Worth doing if other rules need to know
about HEEx-interpolated calls.

## defimpl-aware rules (added 2026-04-29 round 3 from Livebook)

`defimpl Protocol, for: Type do ... end` defines functions whose names and
arities are FIXED by the protocol's `defprotocol`. Treating them as ordinary
free functions causes false positives in:

| Rule | False positive | Why |
|---|---|---|
| **6.10** Non-bang raises | `def write(_, _, _), do: raise("not implemented")` (filesystem stub) | Protocol pins the name; `write!` would break the impl |
| **6.34** Dead private | `defp` helpers used only inside the defimpl body | (Already fixed in BUG-5 by scope-aware extraction; verify) |
| **6.43** Long parameter list | Protocol callback with 5+ args | Fixed by protocol; `defimpl` author can't change arity |
| **6.10/6.16** GenServer.call patterns | If protocol callback bodies use call patterns | The contract dictates the shape |

**Suggested helper:** `AST.collect_defimpl_callbacks/1` returning
`MapSet.new([{name, arity}, ...])` — every `def` inside any `defimpl` block.
Rules check membership and exempt. Same shape as the @impl-set in BUG-8's
fix.

**Companion topic:** the same protocol callbacks are EXPECTED to raise
"not implemented" for partial implementations of optional callbacks. A
rule could even POSITIVELY validate the pattern: `defimpl FileSystem,
for: ReadOnly do def write(_, _, _), do: raise("not implemented") end`
is the canonical "I implement only the read side" signal. Worth a rule
of its own (or a positive note rather than a warning).

## Substring-vs-namespace pitfalls (added 2026-04-29 round 3)

Rule 1.26 (Reverse dependency on web layer) was found to match "Web"
substring rather than the `*Web` namespace tail segment. Same class of
bug likely lurks in:

| Rule | Substring match likely wrong on |
|---|---|
| 1.26 reverse dep on web | `Livebook.Teams.WebSocket`, `MyApp.Webhook`, `MyApp.WebrtcClient` |
| Any "is this a web module?" check | same |
| Test/migration/config classifiers | `MyApp.Migrator` (not migration), `MyApp.Tester` (not test) |

**Fix pattern:** classify by last namespace segment OR full namespace
prefix, never substring. A `MyApp.Foo.Web` module IS web layer; a
`MyApp.Web.Foo` module IS web layer (prefix); a `MyApp.Foo.WebSocket`
module is NOT web layer (just contains the substring).

Companion topic: **supervisor / application files exempt from boundary
rules**. `lib/my_app/application.ex` and similar legitimately reference
every supervised child including the Web Endpoint. Rule 1.26 (and
likely several 4.x rules) should skip files that contain `use
Application` or are at the path `lib/<app>/application.ex`. Add to
`Phoenix.classify_file/1` if implemented.

## Phoenix.classify_file/1 — promote to a cross-cutting helper (added 2026-04-29 round 4)

After fixing BUG-7 through BUG-10, six rules now need to know "what kind of
file is this?" — and each implements its own ad-hoc check:

| Rule | What it asks | Current detection |
|---|---|---|
| 1.26 reverse dep on web | "Is this an app supervisor?" | `Path.basename(file) == "application.ex"` + `AST.uses_module?(ast, Application)` (BUG-10) |
| 6.34 dead private | "Is this a Phoenix component with embed_templates?" | AST scan for `embed_templates` calls (BUG-7) |
| 6.34 / 6.10 / 6.43 | "Is this def inside a defimpl?" | Walk-and-collect into MapSet (BUG-9) |
| 7.25 untested module | "Is this a controller / view / live module?" | Path substring `_web/`, `controllers/`, `live/` |
| 4.19 missing telemetry | "Is this a context facade?" | Path-based heuristic |
| (proposed N+1) | "Is this a LiveView module?" | `use Phoenix.LiveView` AST check |

**Suggested API:**

```elixir
Phoenix.classify_file(file, ast) :: %{
  layer: :application_root | :web | :live_view | :component | :controller |
         :view | :router | :context | :schema | :migration | :test | :other,
  uses: %{phoenix_live_view?: bool, ecto_schema?: bool, application?: bool, ...},
  embed_templates: [String.t()],   # the globs declared via `embed_templates`
  defimpl_callbacks: MapSet.t({atom(), arity()}),  # name+arity inside defimpls
  impl_callbacks: MapSet.t({atom(), arity()}),     # name+arity with @impl
}
```

Compute once per file, pass via `opts`. Each rule reads what it needs.
Eliminates 4-5 duplicate AST walks per file at scan time, centralizes the
Phoenix-shape knowledge in one place, and makes the next BUG-N similar fix a
one-line addition to the classifier.

## Cross-project finding density (added 2026-04-29 round 4 — methodology)

After 4 field-test cycles, finding density per 1k LoC settled at:

| Project | Type | LoC | Findings | Density |
|---|---|---:|---:|---:|
| PhiaUI | UI library (stateless components) | 127k | 932 | **7/k** |
| phoenix_live_dashboard | Live UI controls | 7k | 98 | **14/k** |
| Livebook | Phoenix app (after this round's fixes) | 67k | 1851 | **28/k** |
| hexpm | Phoenix prod app | 34k | 1192 | **35/k** |

**Pattern:** density correlates with statefulness and architectural surface
area. UI libraries (mostly pure functions) find few issues; production
Phoenix apps (controllers, contexts, supervision, OTP) find many. The
Layer 1 mechanical scan exposes more rules per kLoC the more your code
participates in the Phoenix/OTP runtime.

**Implication for new rules:** target the dense end of the spectrum. A
LiveView-specific rule is more likely to find real issues per analysis
second than a generic style rule.

## Field-test cycle as a development practice (added 2026-04-29 round 4)

Every cycle has surfaced 1-3 new false-positive classes that weren't visible
in self-analysis:

| Cycle | Project | Bugs surfaced | Pattern |
|---|---|---|---|
| 1 | PhiaUI | BUG-1 (`when/N` name), BUG-2 (Map.put as I/O), BUG-3 (multi-clause recursion) | UI-library idioms |
| 2 | hexpm | BUG-4 (HEEx invocations), BUG-5 (defimpl/Mix.env scoping), BUG-6 (metadata bloat) | Production Phoenix |
| 3 | PLD | BUG-7 (embed_templates), BUG-8 (@impl callbacks) | Live UI control idioms |
| 4 | Livebook | BUG-9 (defimpl callbacks), BUG-10 (Web namespace + app supervisor) | Heavy protocol/supervisor code |

**Conclusion:** self-analysis confirms correctness; field tests reveal
blind spots. Both are necessary. Recommend running Archdo against at least
one project per category (UI library, Phoenix app, OTP-heavy app, embedded
Nerves app) before each release.

## Open questions for designing rules

- Should LiveView-specific rules live under category 1.x (boundary), 4.x (coupling), or get a new category 12.x (Phoenix/LiveView)?
- For the BUG-4 HEEx scan in `dead_private_function.ex`: should this scanning be hoisted into `AST` (or a `Phoenix.HEEx` helper) so other rules can reuse it for "is this function called from a template" questions?
- Should `--phoenix` be a flag like `--compiled`, enabling Phoenix-specific rules only when the project is detected as Phoenix? Detection: `mix.exs` deps include `:phoenix` or `:phoenix_live_view`.
