# cancancan_cr — 1:1 port of CanCanCan 3.6.1 core to Crystal over
# active_record_cr.

Status / scope (see oracle/ for the source of truth):

- `CanCan::Ability` module to include into an ability class (same shape
  as the gem): `can`/`cannot` (action arrays, subject arrays, `:all`,
  `:manage`, conditions hash, raw-SQL string, Relation scopes,
  attribute arrays / single attributes, blocks, catch-all blocks,
  two-argument attribute blocks), `can?`/`cannot?` (incl. the
  `{any: [...]}` multi-subject and the nested `{parent => child}`
  subject forms), `authorize!` (`CanCan::AccessDenied` with
  action/subject/message), `attributes_for`, `has_block?`/`has_raw_sql?`,
  `merge`, `permissions`, `permitted_attributes`,
  `unauthorized_message`, `alias_action` (with real-action target
  validation) + default aliases (read/create/update),
  `clear_aliased_actions`, `expand_actions`.
- `CanCan::Rule` with the gem's relevance and conditions matching
  (hash / range / array / nested hash, empty-has-nil semantics,
  belongs_to single-record conditions, class-subjects ignore
  conditions, last-rule-wins ordering) and the gem's `#inspect`
  rendering (subjects through the Rails-format `Model.inspect`).
- `Model.accessible_by(ability, action)`: full port of the gem's AR
  adapter pipeline — `RulesCompressor` (duplicate-conditions dedupe +
  catch-all collapse), scope (Relation) override with the
  merge-with-other-conditions error, single-can fast path, and the
  AND/OR/NOT fold over multiple rules; array → IN, ranges → BETWEEN
  (exclusive end minus one), nested hashes → (NOT) EXISTS subqueries
  through association joins (same result sets as the gem's LEFT JOIN
  aliasing).
- Controller additions (`src/controller_additions.cr`), two layers:
  - Layer 1 — the `ControllerAdditions` seam (params/ivar-store/
    current_ability/cancan_action/skips/param sanitizer) and
    `CanCan::ControllerResource` (load/authorize, `new`/`create` vs
    member actions, `find_by`, `through` parents, collection loading
    via `accessible_by`, sanitization), oracle-covered by the 33
    `ctrl_*` cases.
  - Layer 2 — `load_and_authorize_resource` / `load_resource` /
    `authorize_resource` macros on `ActionController::Base`
    (action_pack_cr): before-action filter + typed resource getters;
    `CanCan.register_model` (macro) feeds a compile-time registry that
    a `macro finished` expands into `CanCan.model_*` dispatchers
    (find/new/assign/accessible_by/table_name/assoc_specs per
    registered class) and per-controller `cancan_action` string→Symbol
    maps — per-model AR codegen methods are unreachable from the
    static `Base.class` type, so every dispatch calls on the class
    literal.

Deviations (documented; oracle cases kept 1:1 in semantics):

- Blocks receive subjects typed as a union (`ActiveRecord::Base | Symbol
  | String`); spec blocks cast with `.as(Model)`. Catch-all blocks take
  `(action, object_class, object)` exactly like the gem.
- Conditions matching reads records through `cancan_attribute(name)`
  (columns via `[]`; models override to expose associations — `[]` is
  generated per subclass in active_record_cr and is not callable on the
  base type).
- `permissions` returns the rendered string identical to the gem's
  Hash#inspect instead of a nested Hash (no symbol-keyed runtime hashes
  in Crystal).
- `permitted_attributes` returns `Array(String)` instead of an Array of
  runtime-manufactured symbols (Crystal has no `String#to_sym`); the
  oracle spec renders them back into the gem's `:sym` list format.
- Crystal syntax adaptations of Ruby forms (semantics 1:1): the
  `{any: [...]}` subject is `can?(:read, any: [Article, ...] of
  CanCan::Subject)`; the nested `{parent => child}` subject is
  `can?(:read, parent: article, child: comment)`; Relation-scope
  conditions are captured at `can` time into a `CanCan::RawScope`
  (Crystal cannot union `Relation(T)` across models) — `can?` raises
  `CanCan::Error` through the same only-raw-sql path as the gem, and
  `accessible_by` re-applies the captured WHERE fragments.
- SQL fragments inline escaped literals (strings quote-doubled) instead
  of bind parameters (`Relation#where(String, *args)` cannot take a
  runtime args array); result sets and `to_sql` column references match
  the oracle.
- Controller additions deviations: no runtime
  `instance_variable_set`/`send`/`constantize` — resources live in a
  typed seam store with generated getters, and model classes resolve
  through the `CanCan.register_model` compile-time registry (the
  resource macros auto-register their model); no `String#to_sym` —
  action names resolve via generated `cancan_action` maps; skips are
  instance-level `cancan_skip(...)` calls (macro sugar like
  `skip_load_resource` is omitted — action_pack filters run in
  registration order); `check_authorization`/`after_action` hooks are
  out of scope. L2 integration needs `params["controller"]/["action"]`
  set by the dispatcher — patched in rails.cr (see the action_pack
  `__set_params` route-params change and the railties middleware
  passing `match.route.controller`/`action`).
- Controller additions are ported as two layers (see below); RSpec
  matchers are out of scope.
- Merge cases use the Symbol subject `:user` instead of a plain Ruby
  class (all oracle subjects are AR models or symbols anyway).

Oracle: gem 3.6.1 over SQLite in-memory (`oracle/cases.rb`), cases
mirroring the gem's rspec suite; the Crystal spec replays them 1:1
against PostgreSQL and must reproduce `oracle/expected.yml` exactly
(133 cases: 100 core + 33 `ctrl_*`; `ruby oracle/cases.rb`
regenerates the file verbatim).
