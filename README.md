# cancancan.cr

A 1:1 Crystal port of **CanCanCan 3.6.1** authorization on top of
`active_record.cr`. Namespace `CanCan` mirrors the gem; abilities,
rules, SQL-scope extraction (`accessible_by`) and controller
`load_and_authorize_resource` behave like the original.

> ⚠️ EXPERIMENTAL — DO NOT USE IN PRODUCTION YET.

## Installation

```yaml
dependencies:
  cancancan_cr:
    github: OrelSokolov/cancancan.cr
```

```sh
shards install
```

Depends on `active_record.cr` and `action_pack.cr` (controller layer).

## Usage

```crystal
class Ability
  include CanCan::Ability

  def initialize(user)
    can :read, Post
    can :manage, Post, author_id: user.id
    cannot :destroy, Post, featured: true
  end
end

ability.can?(:read, post)
posts = Post.accessible_by(ability, :read)
```

```crystal
class PostsController < ApplicationController
  load_and_authorize_resource
end
```

## Feature comparison vs cancancan 3.6.1

### Ability DSL

| Feature | Original (cancancan) | Port (cancancan.cr) | Status |
|---|---|---|---|
| `can` / `cannot` (action arrays, subject arrays, `:all`, `:manage`, conditions hash, raw-SQL string, Relation scopes, attribute arrays/single attributes, blocks, catch-all blocks, two-argument attribute blocks) | ✅ | Same | ✅ |
| `can?` / `cannot?`, incl. `{any: [...]}` multi-subject and nested `{parent => child}` forms | ✅ | Crystal syntax: `can?(:read, any: [Article] of CanCan::Subject)` and `can?(:read, parent: article, child: comment)` — semantics 1:1 | 🔶 |
| `authorize!` (`CanCan::AccessDenied` with action/subject/message) | ✅ | Same | ✅ |
| `attributes_for`, `has_block?`/`has_raw_sql?`, `merge`, `permissions`, `permitted_attributes`, `unauthorized_message` | ✅ | `permissions` renders the gem's `Hash#inspect` string (no runtime symbol-keyed hashes); `permitted_attributes` returns `Array(String)` | 🔶 |
| `alias_action` (+ default read/create/update aliases, real-action target validation), `clear_aliased_actions`, `expand_actions` | ✅ | Same | ✅ |

### Rules & scope extraction

| Feature | Original | Port | Status |
|---|---|---|---|
| `CanCan::Rule` relevance/conditions matching (hash / range / array / nested hash, empty-has-nil semantics, belongs_to single-record, class-subjects ignore conditions, last-rule-wins) | ✅ | Same, incl. gem-identical `#inspect` | ✅ |
| `Model.accessible_by(ability, action)` — full AR adapter pipeline | ✅ | RulesCompressor (duplicate dedupe + catch-all collapse), scope override with merge error, single-can fast path, AND/OR/NOT fold; array → IN, ranges → BETWEEN, nested hashes → (NOT) EXISTS subqueries via association joins (same result sets as the gem's LEFT JOIN aliasing) | ✅ |
| SQL fragments with bind parameters | ✅ | Inline escaped literals (strings quote-doubled) — `Relation#where(String, *args)` cannot take a runtime args array; result sets and `to_sql` column references match the oracle | 🔶 |

### Controller additions

| Feature | Original | Port | Status |
|---|---|---|---|
| `ControllerAdditions` seam (params/ivar store/current_ability/cancan_action/skips/param sanitizer) | ✅ | Same, oracle-covered (33 `ctrl_*` cases) | ✅ |
| `ControllerResource` (load/authorize, new/create vs member actions, `find_by`, `through` parents, collection via `accessible_by`, sanitization) | ✅ | Same | ✅ |
| `load_and_authorize_resource` / `load_resource` / `authorize_resource` macros on `ActionController::Base` | ✅ | Before-action filter + typed resource getters; model classes resolve via the `CanCan.register_model` compile-time registry (auto-registered by the macros) | 🔶 |
| `skip_load_resource`-style macro sugar | ✅ | Instance-level `cancan_skip(...)` calls (action_pack filters run in registration order) | 🔶 |
| `check_authorization` / `after_action` verify hooks, RSpec matchers | ✅ | Out of scope | ❌ |

## Deviations & Crystal-specific notes

- No runtime `instance_variable_set`/`send`/`constantize` — resources
  live in a typed seam store with generated getters; no `String#to_sym` —
  action names resolve via generated `cancan_action` maps.
- Blocks receive subjects typed as a union (`ActiveRecord::Base | Symbol
  | String`); spec blocks cast with `.as(Model)`.
- Conditions matching reads records through `cancan_attribute(name)`
  (columns via `[]`; models override it to expose associations).
- Relation-scope conditions are captured at `can` time into
  `CanCan::RawScope` (Crystal cannot union `Relation(T)` across models);
  `accessible_by` re-applies the captured WHERE fragments.
- Merge cases use the Symbol subject `:user` instead of a plain Ruby
  class (all oracle subjects are AR models or symbols anyway).

## Testing

```sh
crystal spec
```

Oracle: gem 3.6.1 over SQLite in-memory (`oracle/cases.rb`), cases
mirroring the gem's rspec suite. The Crystal spec replays them 1:1
against PostgreSQL and must reproduce `oracle/expected.yml` exactly —
133 cases (100 core + 33 `ctrl_*`). `ruby oracle/cases.rb` regenerates
the expected file verbatim.
