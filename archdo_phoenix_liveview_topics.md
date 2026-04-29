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

## Open questions for designing rules

- Should LiveView-specific rules live under category 1.x (boundary), 4.x (coupling), or get a new category 12.x (Phoenix/LiveView)?
- For the BUG-4 HEEx scan in `dead_private_function.ex`: should this scanning be hoisted into `AST` (or a `Phoenix.HEEx` helper) so other rules can reuse it for "is this function called from a template" questions?
- Should `--phoenix` be a flag like `--compiled`, enabling Phoenix-specific rules only when the project is detected as Phoenix? Detection: `mix.exs` deps include `:phoenix` or `:phoenix_live_view`.
