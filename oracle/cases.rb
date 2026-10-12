# Oracle cases for cancancan 3.6.1 (core Ability/Rule + AR accessible_by).
# Cases mirror the gem's rspec suite semantics (spec/cancan/**) minus
# Rails-controller and RSpec-matcher parts.
#
# Run against the ORIGINAL gem:
#   ruby oracle/cases.rb > oracle/expected.yml
#
# Each line: "<case_id>\t<value>" (control chars escaped). Mirrored 1:1
# in spec/oracle_spec.cr.

gem "cancancan", "= 3.6.1"
gem "activerecord", "= 8.1.4"
gem "activesupport", "= 8.1.4"
gem "sqlite3", ">= 2.1"
require "active_record"
require "cancan"

ActiveRecord::Migration.verbose = false
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.define do
  create_table :articles do |t|
    t.string  :title
    t.boolean :published, default: false, null: false
    t.integer :priority, default: 0
    t.integer :user_id
    t.timestamps
  end
  create_table :comments do |t|
    t.integer :article_id
    t.string  :body
  end
end

class PlainAbility
  include CanCan::Ability
end

class Article < ActiveRecord::Base
  has_many :comments
end

class Comment < ActiveRecord::Base
  belongs_to :article
end

def render(v)
  s = v.is_a?(String) ? v : v.inspect
  s.gsub("\\", "\\\\\\\\").gsub("\n", "\\n").gsub("\t", "\\t").gsub("\r", "\\r")
end

def case_run(id)
  puts "#{id}\t#{render(yield)}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class.name}"
end

ARTICLES = [
  Article.create!(title: "pub a", published: true,  priority: 1, user_id: 1),
  Article.create!(title: "priv b", published: false, priority: 2, user_id: 1),
  Article.create!(title: "pub c", published: true,  priority: 3, user_id: 2)
]

# --- aliases (ability actions spec) ----------------------------------------
class AliasAbility
  include CanCan::Ability
  def initialize
    alias_action :update, :destroy, to: :modify
  end
end
alias_ability = AliasAbility.new
case_run("alias_default_read")   { alias_ability.aliased_actions[:read] }
case_run("alias_default_create") { alias_ability.aliased_actions[:create] }
case_run("alias_default_update") { alias_ability.aliased_actions[:update] }
case_run("alias_custom")         { alias_ability.aliased_actions[:modify] }
case_run("alias_expands") do
  a = AliasAbility.new
  a.can :modify, :all
  [a.can?(:update, :all), a.can?(:destroy, :all), a.can?(:create, :all)]
end
case_run("alias_reverse_not_matched") do
  a = AliasAbility.new
  a.can :update, :all
  a.can?(:modify, :all)
end

# --- basic can?/cannot? (ability spec) -------------------------------------
basic = PlainAbility.new
basic.can :read, :all
case_run("basic_read_all")      { basic.can?(:read, Article) }
case_run("basic_read_instance") { basic.can?(:read, Article.new) }
case_run("basic_cannot_write")  { basic.can?(:update, Article) }
case_run("basic_cannotq")       { basic.cannot?(:update, Article) }

manage = PlainAbility.new
manage.can :manage, Article
case_run("manage_matches_all_actions") do
  [:read, :create, :update, :destroy, :custom].map { |a| manage.can?(a, Article) }
end
case_run("manage_instance")     { manage.can?(:read, Article.new) }
case_run("manage_other_subject") { manage.can?(:read, Comment) }

array = PlainAbility.new
array.can [:read, :update], [Article, Comment]
case_run("array_actions_subjects") do
  [:read, :update, :destroy].map { |a| [array.can?(a, Article), array.can?(a, Comment)] }
end

symbol_subject = PlainAbility.new
symbol_subject.can :read, :stats
case_run("symbol_subject")       { symbol_subject.can?(:read, :stats) }
case_run("symbol_subject_other") { symbol_subject.can?(:read, :dashboard) }

# --- cannot overrides (order matters) --------------------------------------
override = PlainAbility.new
override.can :read, :all
override.cannot :read, Article
case_run("cannot_overrides") do
  [override.can?(:read, Article), override.can?(:read, Comment)]
end

partial = PlainAbility.new
partial.can :read, :all
partial.cannot :read, Article, published: false
case_run("cannot_with_conditions") do
  partial.can?(:read, ARTICLES[0]) # published
end
case_run("cannot_with_conditions_blocked") do
  partial.can?(:read, ARTICLES[1]) # unpublished
end

last_wins = PlainAbility.new
last_wins.cannot :read, :all
last_wins.can :read, Article
case_run("last_rule_wins") { last_wins.can?(:read, Article) }

# --- conditions hash (rule/conditions_matcher spec) ------------------------
cond = PlainAbility.new
cond.can :read, Article, published: true
case_run("cond_match")        { cond.can?(:read, Article.new(published: true)) }
case_run("cond_no_match")     { cond.can?(:read, Article.new(published: false)) }
case_run("cond_class_ignores") { cond.can?(:read, Article) }

multi = PlainAbility.new
multi.can :read, Article, priority: 1..3, user_id: [1, 2]
case_run("cond_range_ok")    { multi.can?(:read, Article.new(priority: 2, user_id: 1)) }
case_run("cond_range_out")   { multi.can?(:read, Article.new(priority: 5, user_id: 1)) }
case_run("cond_array_ok")    { multi.can?(:read, Article.new(priority: 1, user_id: 2)) }
case_run("cond_array_out")   { multi.can?(:read, Article.new(priority: 1, user_id: 3)) }

nested = PlainAbility.new
nested.can :read, Article, comments: { body: "hi" }
case_run("cond_nested_match") do
  a = Article.new(comments: [Comment.new(body: "hi")])
  nested.can?(:read, a)
end
case_run("cond_nested_no_match") do
  a = Article.new(comments: [Comment.new(body: "yo")])
  nested.can?(:read, a)
end
case_run("cond_nested_empty_has_nil") do
  nested.can?(:read, Article.new(comments: []))
end

multi_cond = PlainAbility.new
multi_cond.can :read, Article, published: true, priority: 2
case_run("cond_all_must_match") do
  multi_cond.can?(:read, Article.new(published: true, priority: 2))
end
case_run("cond_one_missing") do
  multi_cond.can?(:read, Article.new(published: true, priority: 1))
end

# --- block conditions -------------------------------------------------------
block = PlainAbility.new
block.can :read, Article do |article|
  article.priority > 1
end
case_run("block_match")     { block.can?(:read, Article.new(priority: 2)) }
case_run("block_no_match")  { block.can?(:read, Article.new(priority: 1)) }
case_run("block_class_true") { block.can?(:read, Article) }

cannot_block = PlainAbility.new
cannot_block.can :read, :all
cannot_block.cannot :read, Article do |article|
  article.priority > 2
end
case_run("cannot_block_allowed") { cannot_block.can?(:read, Article.new(priority: 1)) }
case_run("cannot_block_blocked") { cannot_block.can?(:read, Article.new(priority: 3)) }

# --- match_all block --------------------------------------------------------
catch_all = PlainAbility.new
catch_all.can do |action, object_class, object|
  action == :read && object_class == Article
end
case_run("catch_all_class")    { catch_all.can?(:read, Article) }
case_run("catch_all_instance") { catch_all.can?(:read, Article.new) }
case_run("catch_all_other")    { catch_all.can?(:update, Article) }

# --- attributes (strong parameter support) ---------------------------------
attr_ability = PlainAbility.new
attr_ability.can :read, :all
attr_ability.cannot :read, Article, [:secret_field]
case_run("attribute_blocked") do
  attr_ability.can?(:read, Article, :secret_field)
end
case_run("attribute_allowed") do
  attr_ability.can?(:read, Article, :title)
end
case_run("attributes_for") do
  a = PlainAbility.new
  a.can :create, Article, published: true, priority: 5, user_id: 7
  a.attributes_for(:create, Article)
end

# --- authorize! / AccessDenied ----------------------------------------------
auth = PlainAbility.new
auth.can :read, Article
case_run("authorize_ok") { auth.authorize!(:read, Article.new).class.name }
case_run("authorize_raises") do
  auth.authorize!(:update, Article.new)
  "no_raise"
rescue CanCan::AccessDenied => e
  "#{e.class.name}:#{e.action}:#{e.subject.class.name}"
end
case_run("authorize_custom_message") do
  a = PlainAbility.new
  a.cannot :update, Article
  begin
    a.authorize!(:update, Article.new, message: "no way")
  rescue CanCan::AccessDenied => e
    e.message
  end
end

# --- merge ------------------------------------------------------------------
class ReadAbility
  include CanCan::Ability
  def initialize
    can :read, User
  end
end
class WriteAbility
  include CanCan::Ability
  def initialize
    can :edit, User
  end
end
class User; end
merged = ReadAbility.new
merged.merge(WriteAbility.new)
case_run("merge_before") { ReadAbility.new.can?(:edit, User) }
case_run("merge_after")  { merged.can?(:edit, User) && merged.can?(:read, User) }

# --- permissions hash -------------------------------------------------------
perms = PlainAbility.new
perms.can :read, Article
perms.cannot :destroy, Article
case_run("permissions") { perms.permissions }

# --- accessible_by (AR adapter) ---------------------------------------------
accessible = PlainAbility.new
accessible.can :read, Article, published: true
case_run("accessible_by_titles") do
  Article.accessible_by(accessible).map(&:title).sort
end
case_run("accessible_by_sql") do
  Article.accessible_by(accessible).to_sql.include?("published")
end

accessible_block = PlainAbility.new
accessible_block.can :read, Article do |a|
  a.priority > 1
end
case_run("accessible_by_block_raises") do
  Article.accessible_by(accessible_block)
  "no_raise"
rescue CanCan::Error => e
  e.class.name
end

# --- raw sql conditions ------------------------------------------------------
raw = PlainAbility.new
raw.can :read, Article, "priority > 1"
case_run("raw_sql_can_raises") do
  raw.can?(:read, ARTICLES.first)
  "no_raise"
rescue CanCan::Error => e
  e.class.name
end
case_run("raw_sql_accessible_by") do
  Article.accessible_by(raw).map(&:title).sort
end

# --- has_block? / has_raw_sql? ----------------------------------------------
hb = PlainAbility.new
hb.can :read, Article do |a|
  a.published
end
case_run("has_block")    { hb.has_block?(:read, Article) }
case_run("has_raw_sql")  { hb.has_raw_sql?(:read, Article) }

# --- clear_aliased_actions ---------------------------------------------------
case_run("clear_aliases") do
  a = PlainAbility.new
  a.clear_aliased_actions
  a.alias_action :destroy, to: :read
  a.can :read, :all
  a.can?(:destroy, :all)
end

# ============================================================================
# Extended cases (second pass): accessible_by SQL generation, :any subjects,
# nested subjects, permitted_attributes, unauthorized_message, scopes,
# alias validation, Rule#inspect.

# extra fixtures: comments + an article no rule from the basic set matches
Comment.create!(article_id: ARTICLES[0].id, body: "hi")
Comment.create!(article_id: ARTICLES[1].id, body: "yo")
Comment.create!(article_id: ARTICLES[2].id, body: "hi there")
SOLO = Article.create!(title: "solo d", published: false, priority: 0, user_id: 3)
C_HI = Comment.find_by!(body: "hi")
C_YO = Comment.find_by!(body: "yo")
C_HI_THERE = Comment.find_by!(body: "hi there")

# --- conditions on belongs_to (single associated record) --------------------
bt_nested = PlainAbility.new
bt_nested.can :read, Comment, article: {published: true}
case_run("cond_belongs_to_match")    { bt_nested.can?(:read, C_HI) }        # article published
case_run("cond_belongs_to_no_match") { bt_nested.can?(:read, C_YO) }       # article unpublished

# --- empty-children has_nil semantics on persisted records -----------------
no_children = PlainAbility.new
no_children.can :read, Article, comments: {id: nil}
case_run("cond_no_children") { no_children.can?(:read, SOLO) }             # no comments
case_run("cond_has_children") { no_children.can?(:read, ARTICLES[0]) }     # has a comment

# --- block receiving the attribute argument --------------------------------
attr_block = PlainAbility.new
attr_block.can(:read, Article) { |_a, attr| attr == :title }
case_run("block_attribute_match")    { attr_block.can?(:read, Article.new, :title) }
case_run("block_attribute_no_match") { attr_block.can?(:read, Article.new, :body) }

# --- :any => [...] multi-subject queries -------------------------------------
any_ab = PlainAbility.new
any_ab.can :read, [Article, Comment]
case_run("any_subject_match") { any_ab.can?(:read, any: [Article, Comment]) }
case_run("any_subject_one")   { any_ab.can?(:read, any: [Comment]) }
case_run("any_subject_none")  { any_ab.can?(:read, any: [:stats]) }

any_cond = PlainAbility.new
any_cond.can :read, Comment, body: "hi"
case_run("any_subject_conditions")     { any_cond.can?(:read, any: [C_HI, :stats]) }
case_run("any_subject_conditions_none") { any_cond.can?(:read, any: [C_YO, :stats]) }

# --- nested subject {parent => child} ----------------------------------------
nested_sub = PlainAbility.new
nested_sub.can :read, Comment, article: {published: true}
case_run("nested_subject_match")     { nested_sub.can?(:read, ARTICLES[0] => C_HI) }
case_run("nested_subject_no_match")  { nested_sub.can?(:read, ARTICLES[1] => C_YO) }

nested_fk = PlainAbility.new
nested_fk.can :read, Comment, article_id: ARTICLES[0].id
case_run("nested_subject_fk_match")    { nested_fk.can?(:read, ARTICLES[0] => C_HI) }
case_run("nested_subject_fk_no_match") { nested_fk.can?(:read, ARTICLES[1] => C_HI) }

nested_fk_arr = PlainAbility.new
nested_fk_arr.can :read, Comment, article_id: [ARTICLES[0].id, ARTICLES[1].id]
case_run("nested_subject_fk_arr_match")    { nested_fk_arr.can?(:read, ARTICLES[1] => C_YO) }
case_run("nested_subject_fk_arr_no_match") { nested_fk_arr.can?(:read, ARTICLES[2] => C_HI_THERE) }

# --- permitted_attributes ------------------------------------------------------
pa = PlainAbility.new
pa.can :manage, Article, [:title, :published]
pa.cannot :manage, Article, :published
case_run("permitted_attributes") do
  pa.permitted_attributes(:update, Article.new).sort
end
case_run("permitted_attributes_all") do
  a = PlainAbility.new
  a.can :manage, Article
  a.permitted_attributes(:update, Article.new).sort
end

# --- unauthorized_message / default message -------------------------------------
case_run("unauthorized_message_nil") { PlainAbility.new.unauthorized_message(:read, Article) }
case_run("authorize_default_message") do
  a = PlainAbility.new
  a.cannot :read, Article
  begin
    a.authorize!(:read, Article.new)
  rescue CanCan::AccessDenied => e
    e.message
  end
end

# --- alias_action target validation ----------------------------------------------
case_run("alias_to_real_action_raises") do
  a = PlainAbility.new
  a.alias_action :foo, to: :read
end

# --- Rule#inspect ------------------------------------------------------------------
case_run("rule_inspect") { CanCan::Rule.new(true, :read, Article, [:title]).inspect }
case_run("rule_inspect_conditions") do
  CanCan::Rule.new(true, :read, Article, published: true).inspect
end

# --- accessible_by: OR over multiple can rules --------------------------------------
acc_or = PlainAbility.new
acc_or.can :read, Article, priority: 1
acc_or.can :read, Article, user_id: 2
case_run("acc_or_titles") { Article.accessible_by(acc_or).map(&:title).sort }

acc_cannot = PlainAbility.new
acc_cannot.can :read, Article, published: true
acc_cannot.cannot :read, Article, priority: 3
case_run("acc_cannot_titles") { Article.accessible_by(acc_cannot).map(&:title).sort }

acc_blank_can = PlainAbility.new
acc_blank_can.cannot :read, Article, priority: 3
acc_blank_can.can :read, Article
case_run("acc_blank_can_titles") { Article.accessible_by(acc_blank_can).map(&:title).sort }

only_cannot = PlainAbility.new
only_cannot.cannot :read, Article, priority: 3
case_run("acc_only_cannot_titles") { Article.accessible_by(only_cannot).map(&:title).sort }

# --- accessible_by: array / range conditions (IN / BETWEEN) ---------------------------
acc_in = PlainAbility.new
acc_in.can :read, Article, priority: [1, 3]
case_run("acc_in_titles") { Article.accessible_by(acc_in).map(&:title).sort }

acc_between = PlainAbility.new
acc_between.can :read, Article, priority: 1..2
case_run("acc_between_titles") { Article.accessible_by(acc_between).map(&:title).sort }

acc_between_excl = PlainAbility.new
acc_between_excl.can :read, Article, priority: 1...3
case_run("acc_between_excl_titles") do
  Article.accessible_by(acc_between_excl).map(&:title).sort
end

# --- accessible_by: nested association conditions (EXISTS) ------------------------------
acc_exists = PlainAbility.new
acc_exists.can :read, Article, comments: {body: "hi"}
case_run("acc_exists_titles") { Article.accessible_by(acc_exists).map(&:title).sort }

acc_no_children = PlainAbility.new
acc_no_children.can :read, Article, comments: {id: nil}
case_run("acc_no_children_titles") do
  Article.accessible_by(acc_no_children).map(&:title).sort
end

bt_acc = PlainAbility.new
bt_acc.can :read, Comment, article: {published: true}
case_run("acc_belongs_to_exists") { Comment.accessible_by(bt_acc).map(&:body).sort }

deep = PlainAbility.new
deep.can :read, Comment, article: {comments: {body: "hi"}}
case_run("acc_deep_nested") { Comment.accessible_by(deep).map(&:body).sort }

# --- accessible_by: raw SQL combination ---------------------------------------------------
raw_combined = PlainAbility.new
raw_combined.can :read, Article, "priority > 1"
raw_combined.cannot :read, Article, "user_id = 1"
case_run("acc_raw_combined_titles") do
  Article.accessible_by(raw_combined).map(&:title).sort
end

# --- rules compressor (duplicate conditions / catch-all collapse) -------------------------
acc_dup = PlainAbility.new
acc_dup.can :read, Article, priority: 1
acc_dup.can :read, Article, priority: 1
acc_dup.cannot :read, Article, published: false
case_run("acc_dup_conditions_titles") { Article.accessible_by(acc_dup).map(&:title).sort }

coll = PlainAbility.new
coll.can :read, Article, priority: 1
coll.cannot :read, Article
coll.cannot :read, Article, user_id: 1
case_run("acc_catch_all_collapse_titles") do
  Article.accessible_by(coll).map(&:title).sort
end
case_run("can_catch_all_no_collapse") { coll.can?(:read, ARTICLES[0]) }

# --- scope (Relation) conditions ------------------------------------------------------------
scope_ab = PlainAbility.new
scope_ab.can :read, Article, Article.where(published: true)
case_run("scope_can_match")     { scope_ab.can?(:read, ARTICLES[0]) }
case_run("scope_can_no_match")  { scope_ab.can?(:read, ARTICLES[1]) }
case_run("scope_accessible_by_titles") do
  Article.accessible_by(scope_ab).map(&:title).sort
end

scope_all = PlainAbility.new
scope_all.can :read, Article, Article.all
case_run("scope_blank_all") { scope_all.can?(:read, ARTICLES[1]) }

# ============================================================================
# Controller additions (third pass): CanCan::ControllerResource (the
# load_and_authorize_resource engine) exercised with a fake controller,
# mirroring the gem's controller_resource/controller_additions specs.

class FakeCanCanController
  include CanCan::ControllerAdditions
  attr_accessor :params

  def initialize(params = {}, ability = nil)
    @params = params.with_indifferent_access
    @ability = ability
  end

  def current_ability
    @ability
  end
end

class SanitizingController < FakeCanCanController
  def article_params
    {title: params[:article][:title]}
  end
end

ctrl_read = PlainAbility.new
ctrl_read.can :read, Article
case_run("ctrl_load_show") do
  c = FakeCanCanController.new({action: "show", controller: "articles", id: ARTICLES[0].id}, ctrl_read)
  CanCan::ControllerResource.new(c).load_resource
  c.instance_variable_get(:@article).title
end
case_run("ctrl_load_edit") do
  c = FakeCanCanController.new({action: "edit", controller: "articles", id: ARTICLES[1].id}, ctrl_read)
  CanCan::ControllerResource.new(c).load_resource
  c.instance_variable_get(:@article).title
end
case_run("ctrl_load_index_titles") do
  c = FakeCanCanController.new({action: "index", controller: "articles"}, ctrl_read)
  CanCan::ControllerResource.new(c).load_resource
  c.instance_variable_get(:@articles).map(&:title).sort
end
case_run("ctrl_load_index_conditions_titles") do
  a = PlainAbility.new
  a.can :read, Article, published: true
  c = FakeCanCanController.new({action: "index", controller: "articles"}, a)
  CanCan::ControllerResource.new(c).load_resource
  c.instance_variable_get(:@articles).map(&:title).sort
end
case_run("ctrl_load_index_block_rule_nil_collection") do
  a = PlainAbility.new
  a.can :read, Article do |article|
    article.priority > 1
  end
  c = FakeCanCanController.new({action: "index", controller: "articles"}, a)
  CanCan::ControllerResource.new(c).load_resource
  c.instance_variable_defined?(:@articles)
end
case_run("ctrl_load_new_initial_attributes") do
  a = PlainAbility.new
  a.can :create, Article, published: true, priority: 5
  c = FakeCanCanController.new({action: "new", controller: "articles"}, a)
  CanCan::ControllerResource.new(c).load_resource
  article = c.instance_variable_get(:@article)
  [article.title, article.published, article.priority]
end
case_run("ctrl_load_create_params") do
  a = PlainAbility.new
  a.can :create, Article, published: true
  c = FakeCanCanController.new(
    {action: "create", controller: "articles", article: {title: "from params", priority: 9}}, a)
  CanCan::ControllerResource.new(c).load_resource
  article = c.instance_variable_get(:@article)
  [article.title, article.published, article.priority]
end
case_run("ctrl_load_create_sanitized") do
  a = PlainAbility.new
  a.can :create, Article
  c = SanitizingController.new(
    {action: "create", controller: "articles", article: {title: "ok", priority: 9}}, a)
  CanCan::ControllerResource.new(c).load_resource
  article = c.instance_variable_get(:@article)
  [article.title, article.priority]
end
case_run("ctrl_load_ivar_preset_not_overwritten") do
  c = FakeCanCanController.new({action: "show", controller: "articles", id: ARTICLES[0].id}, ctrl_read)
  c.instance_variable_set(:@article, ARTICLES[2])
  CanCan::ControllerResource.new(c).load_resource
  c.instance_variable_get(:@article).title
end
case_run("ctrl_load_find_by") do
  c = FakeCanCanController.new({action: "show", controller: "articles", id: "pub c"}, ctrl_read)
  CanCan::ControllerResource.new(c, find_by: :title).load_resource
  c.instance_variable_get(:@article).published
end
case_run("ctrl_load_id_param") do
  c = FakeCanCanController.new({action: "show", controller: "articles", url: ARTICLES[1].id}, ctrl_read)
  CanCan::ControllerResource.new(c, id_param: :url).load_resource
  c.instance_variable_get(:@article).title
end
case_run("ctrl_load_class_option") do
  c = FakeCanCanController.new({action: "show", controller: "articles", id: C_HI.id}, ctrl_read)
  CanCan::ControllerResource.new(c, class: Comment).load_resource
  c.instance_variable_get(:@article).body
end
case_run("ctrl_load_instance_name") do
  c = FakeCanCanController.new({action: "show", controller: "articles", id: ARTICLES[0].id}, ctrl_read)
  CanCan::ControllerResource.new(c, instance_name: :post).load_resource
  c.instance_variable_get(:@post).title
end
case_run("ctrl_load_collection_action") do
  c = FakeCanCanController.new({action: "sort", controller: "articles"}, ctrl_read)
  CanCan::ControllerResource.new(c, collection: [:sort]).load_resource
  c.instance_variable_get(:@articles).map(&:title).size
end
case_run("ctrl_load_new_action_option") do
  c = FakeCanCanController.new({action: "build", controller: "articles"}, ctrl_read)
  CanCan::ControllerResource.new(c, new: [:build]).load_resource
  c.instance_variable_get(:@article).new_record?
end
case_run("ctrl_load_namespaced_controller") do
  c = FakeCanCanController.new({action: "show", controller: "admin/articles", id: ARTICLES[0].id}, ctrl_read)
  CanCan::ControllerResource.new(c).load_resource
  c.instance_variable_get(:@article).title
end
case_run("ctrl_load_through_parent") do
  a = PlainAbility.new
  a.can :read, Comment
  c = FakeCanCanController.new(
    {action: "show", controller: "comments", id: C_HI.id}, a)
  c.instance_variable_set(:@article, ARTICLES[0])
  CanCan::ControllerResource.new(c, through: :article).load_resource
  c.instance_variable_get(:@comment).body
end
case_run("ctrl_load_through_parent_wrong_child") do
  a = PlainAbility.new
  a.can :read, Comment
  c = FakeCanCanController.new(
    {action: "show", controller: "comments", id: C_YO.id}, a)
  c.instance_variable_set(:@article, ARTICLES[0])
  CanCan::ControllerResource.new(c, through: :article).load_resource
  c.instance_variable_get(:@comment)
end
case_run("ctrl_load_through_create") do
  a = PlainAbility.new
  a.can :create, Comment
  c = FakeCanCanController.new(
    {action: "create", controller: "comments", comment: {body: "nested"}}, a)
  c.instance_variable_set(:@article, ARTICLES[2])
  CanCan::ControllerResource.new(c, through: :article).load_resource
  comment = c.instance_variable_get(:@comment)
  [comment.body, comment.article_id]
end
case_run("ctrl_load_through_shallow") do
  a = PlainAbility.new
  a.can :read, Comment
  c = FakeCanCanController.new({action: "show", controller: "comments", id: C_HI.id}, a)
  CanCan::ControllerResource.new(c, through: :article, shallow: true).load_resource
  c.instance_variable_get(:@comment).body
end
case_run("ctrl_load_through_missing_parent_raises") do
  a = PlainAbility.new
  a.can :read, Comment
  c = FakeCanCanController.new({action: "show", controller: "comments", id: C_HI.id}, a)
  CanCan::ControllerResource.new(c, through: :article).load_resource
  "no_raise"
end
case_run("ctrl_load_singleton") do
  a = PlainAbility.new
  a.can :read, Comment
  c = FakeCanCanController.new({action: "show", controller: "comments", id: C_HI.id}, a)
  CanCan::ControllerResource.new(c, singleton: true).load_resource
  c.instance_variable_get(:@comment).body
end
case_run("ctrl_authorize_show") do
  c = FakeCanCanController.new({action: "show", controller: "articles", id: ARTICLES[0].id}, ctrl_read)
  CanCan::ControllerResource.new(c).load_and_authorize_resource
  c.instance_variable_get(:@article).title
end
case_run("ctrl_authorize_denied") do
  a = PlainAbility.new
  a.can :read, Comment
  c = FakeCanCanController.new({action: "show", controller: "articles", id: ARTICLES[0].id}, a)
  CanCan::ControllerResource.new(c).load_and_authorize_resource
  "no_raise"
end
case_run("ctrl_authorize_index_class") do
  c = FakeCanCanController.new({action: "index", controller: "articles"}, ctrl_read)
  CanCan::ControllerResource.new(c).load_and_authorize_resource
  c.instance_variable_get(:@articles).map(&:title).size
end
case_run("ctrl_authorize_parent_nested") do
  a = PlainAbility.new
  a.can :read, Comment, article: {published: true}
  c = FakeCanCanController.new({action: "show", controller: "comments"}, a)
  c.instance_variable_set(:@article, ARTICLES[0])
  CanCan::ControllerResource.new(c, through: :article).authorize_resource
  "no_raise"
end
case_run("ctrl_authorize_parent_nested_denied") do
  a = PlainAbility.new
  a.can :read, Comment, article: {published: true}
  c = FakeCanCanController.new({action: "show", controller: "comments"}, a)
  c.instance_variable_set(:@article, ARTICLES[1])
  CanCan::ControllerResource.new(c, through: :article).authorize_resource
  "no_raise"
end
case_run("ctrl_parent_authorization_action") do
  a = PlainAbility.new
  a.can :show, Comment
  a.cannot :update, Comment
  c = FakeCanCanController.new({action: "update", controller: "comments"}, a)
  c.instance_variable_set(:@comment, C_HI)
  CanCan::ControllerResource.new(c, :comment, parent: true).authorize_resource
  "no_raise"
end
case_run("ctrl_skip_load_only") do
  c = Class.new(FakeCanCanController).new(
    {action: "show", controller: "articles", id: ARTICLES[0].id}, ctrl_read)
  c.class._cancan_skipper = {load: {nil => {only: :show}}, authorize: {}}
  CanCan::ControllerResource.new(c).load_resource
  c.instance_variable_defined?(:@article)
end
case_run("ctrl_skip_load_other_action_loads") do
  c = Class.new(FakeCanCanController).new(
    {action: "edit", controller: "articles", id: ARTICLES[0].id}, ctrl_read)
  c.class._cancan_skipper = {load: {nil => {only: :show}}, authorize: {}}
  CanCan::ControllerResource.new(c).load_resource
  c.instance_variable_get(:@article).title
end
case_run("ctrl_skip_authorize") do
  a = PlainAbility.new
  a.can :read, Comment
  c = Class.new(FakeCanCanController).new(
    {action: "show", controller: "articles", id: ARTICLES[0].id}, a)
  c.class._cancan_skipper = {load: {}, authorize: {nil => {}}}
  CanCan::ControllerResource.new(c).load_and_authorize_resource
  c.instance_variable_get(:@article).title
end
case_run("ctrl_additions_can_helper") do
  c = FakeCanCanController.new({}, ctrl_read)
  [c.can?(:read, Article), c.can?(:update, Article)]
end
case_run("ctrl_additions_authorized_flag") do
  a = PlainAbility.new
  a.can :read, Comment
  c = FakeCanCanController.new({action: "show", controller: "articles", id: ARTICLES[0].id}, a)
  begin
    c.authorize!(:read, ARTICLES[0])
    "authorized"
  rescue CanCan::AccessDenied => e
    "denied:#{e.class.name}"
  end
end
