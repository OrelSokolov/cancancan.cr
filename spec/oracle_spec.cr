# Oracle spec: the Crystal port must reproduce oracle/expected.yml exactly
# (captured from cancancan 3.6.1 over SQLite in-memory). Same case IDs, no
# edits; values use the same \n/\t escape protocol.

require "spec"
require "../src/cancancan_cr"

EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/expected.yml").each_line do |line|
    if line.includes?('\t')
      id, value = line.split('\t', 2)
      hash[id] = value.chomp
    end
  end
  hash
end

def escape(s) : String
  s = s.to_s
  s.gsub("\\", "\\\\\\\\").gsub("\n", "\\n").gsub("\t", "\\t").gsub("\r", "\\r")
end

TEST_URL = ENV["CANCANCAN_TEST_URL"]? ||
           "postgres://root@/crails_cancancan_test?host=/var/run/postgresql"

ActiveRecord::Base.establish_connection(TEST_URL)
conn = ActiveRecord::Base.__session
conn.exec(%(TRUNCATE articles, comments RESTART IDENTITY))

class Article < ActiveRecord::Base
  has_many :comments, foreign_key: "article_id"

  # Association seam for conditions matching (devise_cr-style documented
  # deviation: Ruby reads article.comments via send). An explicitly
  # assigned list wins (unsaved records); persisted records fall back to
  # the database.
  @cancan_comments : Array(Comment)? = nil

  def cancan_comments=(comments : Array(Comment))
    @cancan_comments = comments
  end

  def cancan_attribute(name : String) : CanCan::CondAttr
    if name == "comments"
      if cc = @cancan_comments
        return cc.map(&.as(ActiveRecord::Base))
      end
      if (aid = id)
        return Comment.where(%("article_id" = ?), aid).to_a.map(&.as(ActiveRecord::Base))
      end
      return [] of ActiveRecord::Base
    end
    self[name]
  end
end

class Comment < ActiveRecord::Base
  belongs_to :article

  def cancan_attribute(name : String) : CanCan::CondAttr
    return article if name == "article"
    self[name]
  end
end

def new_article(values : Hash(String, ActiveRecord::Value)) : Article
  a = Article.new
  a.assign_attributes(values)
  a
end

def new_comment(values : Hash(String, ActiveRecord::Value)) : Comment
  c = Comment.new
  c.assign_attributes(values)
  c
end

# Ability containers (PlainAbility in the oracle).
class PlainAbility
  include CanCan::Ability
end

ARTICLES = [
  Article.create!({"title" => "pub a", "published" => true, "priority" => 1_i64, "user_id" => 1_i64}),
  Article.create!({"title" => "priv b", "published" => false, "priority" => 2_i64, "user_id" => 1_i64}),
  Article.create!({"title" => "pub c", "published" => true, "priority" => 3_i64, "user_id" => 2_i64}),
]

# extra fixtures: comments + an article no rule from the basic set matches
Comment.create!({"article_id" => ARTICLES[0].id, "body" => "hi"})
Comment.create!({"article_id" => ARTICLES[1].id, "body" => "yo"})
Comment.create!({"article_id" => ARTICLES[2].id, "body" => "hi there"})
SOLO       = Article.create!({"title" => "solo d", "published" => false, "priority" => 0_i64, "user_id" => 3_i64})
C_HI       = Comment.find_by!(body: "hi")
C_YO       = Comment.find_by!(body: "yo")
C_HI_THERE = Comment.find_by!(body: "hi there")

CASES = {} of String => Proc(String)

# --- aliases ------------------------------------------------------------------
class AliasAbility
  include CanCan::Ability

  def initialize
    alias_action :update, :destroy, to: :modify
  end
end

CASES["alias_default_read"] = -> { AliasAbility.new.aliased_actions[:read].inspect }
CASES["alias_default_create"] = -> { AliasAbility.new.aliased_actions[:create].inspect }
CASES["alias_default_update"] = -> { AliasAbility.new.aliased_actions[:update].inspect }
CASES["alias_custom"] = -> { AliasAbility.new.aliased_actions[:modify].inspect }
CASES["alias_expands"] = -> {
  a = AliasAbility.new
  a.can :modify, :all
  [a.can?(:update, :all), a.can?(:destroy, :all), a.can?(:create, :all)].inspect
}
CASES["alias_reverse_not_matched"] = -> {
  a = AliasAbility.new
  a.can :update, :all
  a.can?(:modify, :all).to_s
}

# --- basic can?/cannot? ---------------------------------------------------------
basic = -> {
  b = PlainAbility.new
  b.can :read, :all
  b
}.call
basic.can :read, :all
CASES["basic_read_all"] = -> { basic.can?(:read, Article).to_s }
CASES["basic_read_instance"] = -> { basic.can?(:read, Article.new).to_s }
CASES["basic_cannot_write"] = -> { basic.can?(:update, Article).to_s }
CASES["basic_cannotq"] = -> { basic.cannot?(:update, Article).to_s }

manage = PlainAbility.new
manage.can :manage, Article
CASES["manage_matches_all_actions"] = -> {
  [:read, :create, :update, :destroy, :custom].map { |a| manage.can?(a, Article) }.inspect
}
CASES["manage_instance"] = -> { manage.can?(:read, Article.new).to_s }
CASES["manage_other_subject"] = -> { manage.can?(:read, Comment).to_s }

array = PlainAbility.new
array.can [:read, :update], [Article, Comment] of CanCan::Subject
CASES["array_actions_subjects"] = -> {
  [:read, :update, :destroy].map { |a| [array.can?(a, Article), array.can?(a, Comment)] }.inspect
}

symbol_subject = PlainAbility.new
symbol_subject.can :read, :stats
CASES["symbol_subject"] = -> { symbol_subject.can?(:read, :stats).to_s }
CASES["symbol_subject_other"] = -> { symbol_subject.can?(:read, :dashboard).to_s }

# --- cannot overrides -----------------------------------------------------------
override = PlainAbility.new
override.can :read, :all
override.cannot :read, Article
CASES["cannot_overrides"] = -> {
  [override.can?(:read, Article), override.can?(:read, Comment)].inspect
}

partial = PlainAbility.new
partial.can :read, :all
partial.cannot :read, Article, {"published" => false}
CASES["cannot_with_conditions"] = -> { partial.can?(:read, ARTICLES[0]).to_s }
CASES["cannot_with_conditions_blocked"] = -> { partial.can?(:read, ARTICLES[1]).to_s }

last_wins = PlainAbility.new
last_wins.cannot :read, :all
last_wins.can :read, Article
CASES["last_rule_wins"] = -> { last_wins.can?(:read, Article).to_s }

# --- conditions hash ------------------------------------------------------------
cond = PlainAbility.new
cond.can :read, Article, {"published" => true}
CASES["cond_match"] = -> { cond.can?(:read, new_article({"published" => true})).to_s }
CASES["cond_no_match"] = -> { cond.can?(:read, new_article({"published" => false})).to_s }
CASES["cond_class_ignores"] = -> { cond.can?(:read, Article).to_s }

multi = PlainAbility.new
multi.can :read, Article, {"priority" => 1_i64..3_i64, "user_id" => [1_i64, 2_i64]}
CASES["cond_range_ok"] = -> { multi.can?(:read, new_article({"priority" => 2_i64, "user_id" => 1_i64})).to_s }
CASES["cond_range_out"] = -> { multi.can?(:read, new_article({"priority" => 5_i64, "user_id" => 1_i64})).to_s }
CASES["cond_array_ok"] = -> { multi.can?(:read, new_article({"priority" => 1_i64, "user_id" => 2_i64})).to_s }
CASES["cond_array_out"] = -> { multi.can?(:read, new_article({"priority" => 1_i64, "user_id" => 3_i64})).to_s }

nested = PlainAbility.new
nested.can :read, Article, {"comments" => {"body" => "hi"}}
nested_match = -> {
  a = Article.new
  a.cancan_comments = [new_comment({"body" => "hi"})]
  nested.can?(:read, a).to_s
}
nested_no_match = -> {
  a = Article.new
  a.cancan_comments = [new_comment({"body" => "yo"})]
  nested.can?(:read, a).to_s
}
nested_empty = -> {
  a = Article.new
  a.cancan_comments = [] of Comment
  nested.can?(:read, a).to_s
}
CASES["cond_nested_match"] = nested_match
CASES["cond_nested_no_match"] = nested_no_match
CASES["cond_nested_empty_has_nil"] = nested_empty

multi_cond = PlainAbility.new
multi_cond.can :read, Article, {"published" => true, "priority" => 2_i64}
CASES["cond_all_must_match"] = -> { multi_cond.can?(:read, new_article({"published" => true, "priority" => 2_i64})).to_s }
CASES["cond_one_missing"] = -> { multi_cond.can?(:read, new_article({"published" => true, "priority" => 1_i64})).to_s }

# --- block conditions -------------------------------------------------------------
block = PlainAbility.new
block.can(:read, Article) { |a| (a.as(Article).priority || 0_i64) > 1_i64 }
CASES["block_match"] = -> { block.can?(:read, new_article({"priority" => 2_i64})).to_s }
CASES["block_no_match"] = -> { block.can?(:read, new_article({"priority" => 1_i64})).to_s }
CASES["block_class_true"] = -> { block.can?(:read, Article).to_s }

cannot_block = PlainAbility.new
cannot_block.can :read, :all
cannot_block.cannot(:read, Article) { |a| (a.as(Article).priority || 0_i64) > 2_i64 }
CASES["cannot_block_allowed"] = -> { cannot_block.can?(:read, new_article({"priority" => 1_i64})).to_s }
CASES["cannot_block_blocked"] = -> { cannot_block.can?(:read, new_article({"priority" => 3_i64})).to_s }

# --- match_all block ----------------------------------------------------------------
catch_all = PlainAbility.new
catch_all.can { |action, object_class, object| action == :read && object_class == Article }
CASES["catch_all_class"] = -> { catch_all.can?(:read, Article).to_s }
CASES["catch_all_instance"] = -> { catch_all.can?(:read, Article.new).to_s }
CASES["catch_all_other"] = -> { catch_all.can?(:update, Article).to_s }

# --- attributes -----------------------------------------------------------------------
attr_ability = PlainAbility.new
attr_ability.can :read, :all
attr_ability.cannot :read, Article, [:secret_field]
CASES["attribute_blocked"] = -> { attr_ability.can?(:read, Article, :secret_field).to_s }
CASES["attribute_allowed"] = -> { attr_ability.can?(:read, Article, :title).to_s }
CASES["attributes_for"] = -> {
  a = PlainAbility.new
  a.can :create, Article, {"published" => true, "priority" => 5_i64, "user_id" => 7_i64}
  attrs = a.attributes_for(:create, Article)
  "{" + attrs.map { |k, v| "#{k}: #{v.inspect}" }.join(", ") + "}"
}

# --- authorize! / AccessDenied ----------------------------------------------------------
auth = PlainAbility.new
auth.can :read, Article
CASES["authorize_ok"] = -> { auth.authorize!(:read, Article.new).class.name }
CASES["authorize_raises"] = -> {
  begin
    auth.authorize!(:update, Article.new)
    "no_raise"
  rescue e : CanCan::AccessDenied
    "#{e.class.name}:#{e.action}:#{e.subject.as(Article).class.name}"
  end
}
CASES["authorize_custom_message"] = -> {
  a = PlainAbility.new
  a.cannot :update, Article
  begin
    a.authorize!(:update, Article.new, message: "no way")
    "no_raise"
  rescue e : CanCan::AccessDenied
    e.message.to_s
  end
}

# --- merge ------------------------------------------------------------------------------
class ReadAbility
  include CanCan::Ability

  def initialize
    can :read, :user
  end
end

class WriteAbility
  include CanCan::Ability

  def initialize
    can :edit, :user
  end
end

merged = ReadAbility.new
merged.merge(WriteAbility.new)
CASES["merge_before"] = -> { ReadAbility.new.can?(:edit, :user).to_s }
CASES["merge_after"] = -> { (merged.can?(:edit, :user) && merged.can?(:read, :user)).to_s }

# --- permissions -----------------------------------------------------------------------
perms = PlainAbility.new
perms.can :read, Article
perms.cannot :destroy, Article
CASES["permissions"] = -> { perms.permissions }

# --- accessible_by ------------------------------------------------------------------------
accessible = PlainAbility.new
accessible.can :read, Article, {"published" => true}
CASES["accessible_by_titles"] = -> { Article.accessible_by(accessible).map(&.title.to_s).sort.inspect }
CASES["accessible_by_sql"] = -> { Article.accessible_by(accessible).to_sql.includes?("published").to_s }

accessible_block = PlainAbility.new
accessible_block.can(:read, Article) { |a| (a.as(Article).published ? true : false) }
CASES["accessible_by_block_raises"] = -> {
  begin
    Article.accessible_by(accessible_block)
    "no_raise"
  rescue e : CanCan::Error
    e.class.name
  end
}

# --- raw sql conditions -------------------------------------------------------------------
raw = PlainAbility.new
raw.can :read, Article, "priority > 1"
CASES["raw_sql_can_raises"] = -> {
  begin
    raw.can?(:read, ARTICLES.first)
    "no_raise"
  rescue e : CanCan::Error
    e.class.name
  end
}
CASES["raw_sql_accessible_by"] = -> { Article.accessible_by(raw).map(&.title.to_s).sort.inspect }

# --- has_block? / has_raw_sql? --------------------------------------------------------------
hb = PlainAbility.new
hb.can(:read, Article) { |a| (a.as(Article).published ? true : false) }
CASES["has_block"] = -> { hb.has_block?(:read, Article).to_s }
CASES["has_raw_sql"] = -> { hb.has_raw_sql?(:read, Article).to_s }

# --- clear_aliased_actions ---------------------------------------------------------------------
CASES["clear_aliases"] = -> {
  a = PlainAbility.new
  a.clear_aliased_actions
  a.alias_action :destroy, to: :read
  a.can :read, :all
  a.can?(:destroy, :all).to_s
}

# --- conditions on belongs_to (single associated record) --------------------
bt_nested = PlainAbility.new
bt_nested.can :read, Comment, {"article" => {"published" => true}}
CASES["cond_belongs_to_match"] = -> { bt_nested.can?(:read, C_HI).to_s }    # article published
CASES["cond_belongs_to_no_match"] = -> { bt_nested.can?(:read, C_YO).to_s } # article unpublished

# --- empty-children has_nil semantics on persisted records -----------------
no_children = PlainAbility.new
no_children.can :read, Article, {"comments" => {"id" => nil}}
CASES["cond_no_children"] = -> { no_children.can?(:read, SOLO).to_s }         # no comments
CASES["cond_has_children"] = -> { no_children.can?(:read, ARTICLES[0]).to_s } # has a comment

# --- block receiving the attribute argument --------------------------------
attr_block = PlainAbility.new
attr_block.can(:read, Article) { |_a, attr| attr == :title }
CASES["block_attribute_match"] = -> { attr_block.can?(:read, new_article({"title" => "x"}), :title).to_s }
CASES["block_attribute_no_match"] = -> { attr_block.can?(:read, new_article({"title" => "x"}), :body).to_s }

# --- :any => [...] multi-subject queries ------------------------------------
any_ab = PlainAbility.new
any_ab.can :read, [Article, Comment] of CanCan::Subject
CASES["any_subject_match"] = -> { any_ab.can?(:read, any: [Article, Comment] of CanCan::Subject).to_s }
CASES["any_subject_one"] = -> { any_ab.can?(:read, any: [Comment] of CanCan::Subject).to_s }
CASES["any_subject_none"] = -> { any_ab.can?(:read, any: [:stats] of CanCan::Subject).to_s }

any_cond = PlainAbility.new
any_cond.can :read, Comment, {"body" => "hi"}
CASES["any_subject_conditions"] = -> { any_cond.can?(:read, any: [C_HI, :stats] of CanCan::Subject).to_s }
CASES["any_subject_conditions_none"] = -> { any_cond.can?(:read, any: [C_YO, :stats] of CanCan::Subject).to_s }

# --- nested subject {parent => child} ----------------------------------------
nested_sub = PlainAbility.new
nested_sub.can :read, Comment, {"article" => {"published" => true}}
CASES["nested_subject_match"] = -> { nested_sub.can?(:read, parent: ARTICLES[0], child: C_HI).to_s }
CASES["nested_subject_no_match"] = -> { nested_sub.can?(:read, parent: ARTICLES[1], child: C_YO).to_s }

nested_fk = PlainAbility.new
nested_fk.can :read, Comment, {"article_id" => ARTICLES[0].id.not_nil!}
CASES["nested_subject_fk_match"] = -> { nested_fk.can?(:read, parent: ARTICLES[0], child: C_HI).to_s }
CASES["nested_subject_fk_no_match"] = -> { nested_fk.can?(:read, parent: ARTICLES[1], child: C_HI).to_s }

nested_fk_arr = PlainAbility.new
nested_fk_arr.can :read, Comment,
  {"article_id" => [ARTICLES[0].id.not_nil!, ARTICLES[1].id.not_nil!]}
CASES["nested_subject_fk_arr_match"] = -> { nested_fk_arr.can?(:read, parent: ARTICLES[1], child: C_YO).to_s }
CASES["nested_subject_fk_arr_no_match"] = -> { nested_fk_arr.can?(:read, parent: ARTICLES[2], child: C_HI_THERE).to_s }

# --- permitted_attributes ------------------------------------------------------
pa = PlainAbility.new
pa.can :manage, Article, [:title, :published]
pa.cannot :manage, Article, :published
render_syms = ->(attrs : Array(String)) { "[#{attrs.sort.map { |a| ":#{a}" }.join(", ")}]" }
CASES["permitted_attributes"] = -> { render_syms.call(pa.permitted_attributes(:update, Article.new)) }
CASES["permitted_attributes_all"] = -> {
  a = PlainAbility.new
  a.can :manage, Article
  render_syms.call(a.permitted_attributes(:update, Article.new))
}

# --- unauthorized_message / default message -------------------------------------
CASES["unauthorized_message_nil"] = -> { PlainAbility.new.unauthorized_message(:read, Article).inspect }
CASES["authorize_default_message"] = -> {
  a = PlainAbility.new
  a.cannot :read, Article
  begin
    a.authorize!(:read, Article.new)
    "no_raise"
  rescue e : CanCan::AccessDenied
    e.message.to_s
  end
}

# --- alias_action target validation ----------------------------------------------
CASES["alias_to_real_action_raises"] = -> { PlainAbility.new.alias_action(:foo, to: :read).inspect }

# --- Rule#inspect ------------------------------------------------------------------
CASES["rule_inspect"] = -> { CanCan::Rule.new(true, :read, Article, attributes: [:title]).inspect }
CASES["rule_inspect_conditions"] = -> {
  CanCan::Rule.new(true, :read, Article, conditions: CanCan.to_cond({"published" => true})).inspect
}

# --- accessible_by: OR over multiple can rules --------------------------------------
acc_or = PlainAbility.new
acc_or.can :read, Article, {"priority" => 1_i64}
acc_or.can :read, Article, {"user_id" => 2_i64}
CASES["acc_or_titles"] = -> { Article.accessible_by(acc_or).map(&.title.to_s).sort.inspect }

acc_cannot = PlainAbility.new
acc_cannot.can :read, Article, {"published" => true}
acc_cannot.cannot :read, Article, {"priority" => 3_i64}
CASES["acc_cannot_titles"] = -> { Article.accessible_by(acc_cannot).map(&.title.to_s).sort.inspect }

acc_blank_can = PlainAbility.new
acc_blank_can.cannot :read, Article, {"priority" => 3_i64}
acc_blank_can.can :read, Article
CASES["acc_blank_can_titles"] = -> { Article.accessible_by(acc_blank_can).map(&.title.to_s).sort.inspect }

only_cannot = PlainAbility.new
only_cannot.cannot :read, Article, {"priority" => 3_i64}
CASES["acc_only_cannot_titles"] = -> { Article.accessible_by(only_cannot).map(&.title.to_s).sort.inspect }

# --- accessible_by: array / range conditions (IN / BETWEEN) ---------------------------
acc_in = PlainAbility.new
acc_in.can :read, Article, {"priority" => [1_i64, 3_i64]}
CASES["acc_in_titles"] = -> { Article.accessible_by(acc_in).map(&.title.to_s).sort.inspect }

acc_between = PlainAbility.new
acc_between.can :read, Article, {"priority" => 1_i64..2_i64}
CASES["acc_between_titles"] = -> { Article.accessible_by(acc_between).map(&.title.to_s).sort.inspect }

acc_between_excl = PlainAbility.new
acc_between_excl.can :read, Article, {"priority" => (1_i64...3_i64)}
CASES["acc_between_excl_titles"] = -> {
  Article.accessible_by(acc_between_excl).map(&.title.to_s).sort.inspect
}

# --- accessible_by: nested association conditions (EXISTS) ------------------------------
acc_exists = PlainAbility.new
acc_exists.can :read, Article, {"comments" => {"body" => "hi"}}
CASES["acc_exists_titles"] = -> { Article.accessible_by(acc_exists).map(&.title.to_s).sort.inspect }

acc_no_children = PlainAbility.new
acc_no_children.can :read, Article, {"comments" => {"id" => nil}}
CASES["acc_no_children_titles"] = -> {
  Article.accessible_by(acc_no_children).map(&.title.to_s).sort.inspect
}

bt_acc = PlainAbility.new
bt_acc.can :read, Comment, {"article" => {"published" => true}}
CASES["acc_belongs_to_exists"] = -> { Comment.accessible_by(bt_acc).map(&.body.to_s).sort.inspect }

deep = PlainAbility.new
deep.can :read, Comment, {"article" => {"comments" => {"body" => "hi"}}}
CASES["acc_deep_nested"] = -> { Comment.accessible_by(deep).map(&.body.to_s).sort.inspect }

# --- accessible_by: raw SQL combination ---------------------------------------------------
raw_combined = PlainAbility.new
raw_combined.can :read, Article, "priority > 1"
raw_combined.cannot :read, Article, "user_id = 1"
CASES["acc_raw_combined_titles"] = -> {
  Article.accessible_by(raw_combined).map(&.title.to_s).sort.inspect
}

# --- rules compressor (duplicate conditions / catch-all collapse) -------------------------
acc_dup = PlainAbility.new
acc_dup.can :read, Article, {"priority" => 1_i64}
acc_dup.can :read, Article, {"priority" => 1_i64}
acc_dup.cannot :read, Article, {"published" => false}
CASES["acc_dup_conditions_titles"] = -> { Article.accessible_by(acc_dup).map(&.title.to_s).sort.inspect }

coll = PlainAbility.new
coll.can :read, Article, {"priority" => 1_i64}
coll.cannot :read, Article
coll.cannot :read, Article, {"user_id" => 1_i64}
CASES["acc_catch_all_collapse_titles"] = -> {
  Article.accessible_by(coll).map(&.title.to_s).sort.inspect
}
CASES["can_catch_all_no_collapse"] = -> { coll.can?(:read, ARTICLES[0]).to_s }

# --- scope (Relation) conditions ------------------------------------------------------------
scope_ab = PlainAbility.new
scope_ab.can :read, Article, Article.where(published: true)
CASES["scope_can_match"] = -> {
  begin
    scope_ab.can?(:read, ARTICLES[0])
    "no_raise"
  rescue e : CanCan::Error
    "raise:#{e.class.name}"
  end
}
CASES["scope_can_no_match"] = -> {
  begin
    scope_ab.can?(:read, ARTICLES[1])
    "no_raise"
  rescue e : CanCan::Error
    "raise:#{e.class.name}"
  end
}
CASES["scope_accessible_by_titles"] = -> {
  Article.accessible_by(scope_ab).map(&.title.to_s).sort.inspect
}

scope_all = PlainAbility.new
scope_all.can :read, Article, Article.all
CASES["scope_blank_all"] = -> {
  begin
    scope_all.can?(:read, ARTICLES[1])
    "no_raise"
  rescue e : CanCan::Error
    "raise:#{e.class.name}"
  end
}

EXPECTED.each do |id, expected|
  it id do
    escape(CASES[id].call).should eq expected
  end
end

# ============================================================================
# Controller additions, layer 1: ControllerResource over the controller seam
# (fake controller; oracle cases ctrl_* 1:1). Action symbols are fixed per
# fake controller — ActionController subclasses get a generated dispatch.

class FakeCanCanController
  include CanCan::ControllerAdditions

  def initialize(params : Hash, ability : CanCan::Ability)
    cancan_set_params(params)
    @ability = ability
  end

  def current_ability : CanCan::Ability
    @ability
  end

  def cancan_action : Symbol?
    case cancan_param("action").to_s
    when "show"   then :show
    when "edit"   then :edit
    when "index"  then :index
    when "new"    then :new
    when "create" then :create
    when "update" then :update
    when "sort"   then :sort
    when "build"  then :build
    else
      nil
    end
  end
end

class SanitizingFakeController < FakeCanCanController
  # the gem's `def article_params; params.require(:article).permit(:title); end`
  def cancan_permitted_params(name : String, action : String) : CanCan::ParamHash?
    raw = cancan_param(name).as?(Hash(String, CanCan::ParamValue))
    raw ? ({"title" => raw["title"]?} of String => CanCan::ParamValue) : nil
  end
end

CanCan.register_model Article
CanCan.register_model Comment

ctrl_read = PlainAbility.new
ctrl_read.can :read, Article

ctrl_params_show = {"action" => "show", "controller" => "articles", "id" => ARTICLES[0].id.not_nil!}
CASES["ctrl_load_show"] = -> {
  c = FakeCanCanController.new(ctrl_params_show, ctrl_read)
  CanCan::ControllerResource.new(c).load_resource
  c.cancan_instance("article").as(Article).title.to_s
}
CASES["ctrl_load_edit"] = -> {
  c = FakeCanCanController.new(
    {"action" => "edit", "controller" => "articles", "id" => ARTICLES[1].id.not_nil!}, ctrl_read)
  CanCan::ControllerResource.new(c).load_resource
  c.cancan_instance("article").as(Article).title.to_s
}
CASES["ctrl_load_index_titles"] = -> {
  c = FakeCanCanController.new({"action" => "index", "controller" => "articles"}, ctrl_read)
  CanCan::ControllerResource.new(c).load_resource
  c.cancan_collection("articles").not_nil!.map(&.as(Article)).map(&.title.to_s).sort.inspect
}
CASES["ctrl_load_index_conditions_titles"] = -> {
  a = PlainAbility.new
  a.can :read, Article, {"published" => true}
  c = FakeCanCanController.new({"action" => "index", "controller" => "articles"}, a)
  CanCan::ControllerResource.new(c).load_resource
  c.cancan_collection("articles").not_nil!.map(&.as(Article)).map(&.title.to_s).sort.inspect
}
CASES["ctrl_load_index_block_rule_nil_collection"] = -> {
  a = PlainAbility.new
  a.can(:read, Article) { |article| (article.as(Article).priority || 0_i64) > 1_i64 }
  c = FakeCanCanController.new({"action" => "index", "controller" => "articles"}, a)
  CanCan::ControllerResource.new(c).load_resource
  c.cancan_collection_defined?("articles").to_s
}
CASES["ctrl_load_new_initial_attributes"] = -> {
  a = PlainAbility.new
  a.can :create, Article, {"published" => true, "priority" => 5_i64}
  c = FakeCanCanController.new({"action" => "new", "controller" => "articles"}, a)
  CanCan::ControllerResource.new(c).load_resource
  article = c.cancan_instance("article").as(Article)
  [article.title, article.published, article.priority].inspect
}
CASES["ctrl_load_create_params"] = -> {
  a = PlainAbility.new
  a.can :create, Article, {"published" => true}
  c = FakeCanCanController.new(
    {"action" => "create", "controller" => "articles",
     "article" => {"title" => "from params", "priority" => 9_i64} of String => CanCan::ParamValue}, a)
  CanCan::ControllerResource.new(c).load_resource
  article = c.cancan_instance("article").as(Article)
  [article.title, article.published, article.priority].inspect
}
CASES["ctrl_load_create_sanitized"] = -> {
  a = PlainAbility.new
  a.can :create, Article
  c = SanitizingFakeController.new(
    {"action" => "create", "controller" => "articles",
     "article" => {"title" => "ok", "priority" => 9_i64} of String => CanCan::ParamValue}, a)
  CanCan::ControllerResource.new(c).load_resource
  article = c.cancan_instance("article").as(Article)
  [article.title, article.priority].inspect
}
CASES["ctrl_load_ivar_preset_not_overwritten"] = -> {
  c = FakeCanCanController.new(ctrl_params_show, ctrl_read)
  c.cancan_set_instance("article", ARTICLES[2])
  CanCan::ControllerResource.new(c).load_resource
  c.cancan_instance("article").as(Article).title.to_s
}
CASES["ctrl_load_find_by"] = -> {
  c = FakeCanCanController.new(
    {"action" => "show", "controller" => "articles", "id" => "pub c"}, ctrl_read)
  CanCan::ControllerResource.new(c, find_by: :title).load_resource
  c.cancan_instance("article").as(Article).published.to_s
}
CASES["ctrl_load_id_param"] = -> {
  c = FakeCanCanController.new(
    {"action" => "show", "controller" => "articles", "url" => ARTICLES[1].id.not_nil!}, ctrl_read)
  CanCan::ControllerResource.new(c, id_param_opt: :url).load_resource
  c.cancan_instance("article").as(Article).title.to_s
}
CASES["ctrl_load_class_option"] = -> {
  c = FakeCanCanController.new(
    {"action" => "show", "controller" => "articles", "id" => C_HI.id.not_nil!}, ctrl_read)
  CanCan::ControllerResource.new(c, model: Comment).load_resource
  c.cancan_instance("article").as(Comment).body.to_s
}
CASES["ctrl_load_instance_name"] = -> {
  c = FakeCanCanController.new(ctrl_params_show, ctrl_read)
  CanCan::ControllerResource.new(c, instance_name_opt: :post).load_resource
  c.cancan_instance("post").as(Article).title.to_s
}
CASES["ctrl_load_collection_action"] = -> {
  c = FakeCanCanController.new({"action" => "sort", "controller" => "articles"}, ctrl_read)
  CanCan::ControllerResource.new(c, collection_actions_opt: [:sort]).load_resource
  c.cancan_collection("articles").not_nil!.size.to_s
}
CASES["ctrl_load_new_action_option"] = -> {
  c = FakeCanCanController.new({"action" => "build", "controller" => "articles"}, ctrl_read)
  CanCan::ControllerResource.new(c, new_actions_opt: [:build]).load_resource
  c.cancan_instance("article").as(Article).new_record?.to_s
}
CASES["ctrl_load_namespaced_controller"] = -> {
  c = FakeCanCanController.new(
    {"action" => "show", "controller" => "admin/articles", "id" => ARTICLES[0].id.not_nil!}, ctrl_read)
  CanCan::ControllerResource.new(c).load_resource
  c.cancan_instance("article").as(Article).title.to_s
}
ctrl_comment_read = PlainAbility.new
ctrl_comment_read.can :read, Comment
CASES["ctrl_load_through_parent"] = -> {
  c = FakeCanCanController.new(
    {"action" => "show", "controller" => "comments", "id" => C_HI.id.not_nil!}, ctrl_comment_read)
  c.cancan_set_instance("article", ARTICLES[0])
  CanCan::ControllerResource.new(c, through: :article).load_resource
  c.cancan_instance("comment").as(Comment).body.to_s
}
CASES["ctrl_load_through_parent_wrong_child"] = -> {
  c = FakeCanCanController.new(
    {"action" => "show", "controller" => "comments", "id" => C_YO.id.not_nil!}, ctrl_comment_read)
  c.cancan_set_instance("article", ARTICLES[0])
  begin
    CanCan::ControllerResource.new(c, through: :article).load_resource
    "no_raise"
  rescue e : ActiveRecord::RecordNotFound
    "raise:#{e.class.name}"
  end
}
CASES["ctrl_load_through_create"] = -> {
  a = PlainAbility.new
  a.can :create, Comment
  c = FakeCanCanController.new(
    {"action" => "create", "controller" => "comments",
     "comment" => {"body" => "nested"} of String => CanCan::ParamValue}, a)
  c.cancan_set_instance("article", ARTICLES[2])
  CanCan::ControllerResource.new(c, through: :article).load_resource
  comment = c.cancan_instance("comment").as(Comment)
  [comment.body, comment.article_id].inspect
}
CASES["ctrl_load_through_shallow"] = -> {
  c = FakeCanCanController.new(
    {"action" => "show", "controller" => "comments", "id" => C_HI.id.not_nil!}, ctrl_comment_read)
  CanCan::ControllerResource.new(c, through: :article, shallow: true).load_resource
  c.cancan_instance("comment").as(Comment).body.to_s
}
CASES["ctrl_load_through_missing_parent_raises"] = -> {
  c = FakeCanCanController.new(
    {"action" => "show", "controller" => "comments", "id" => C_HI.id.not_nil!}, ctrl_comment_read)
  begin
    CanCan::ControllerResource.new(c, through: :article).load_resource
    "no_raise"
  rescue e : CanCan::AccessDenied
    "raise:#{e.class.name}"
  end
}
CASES["ctrl_load_singleton"] = -> {
  c = FakeCanCanController.new(
    {"action" => "show", "controller" => "comments", "id" => C_HI.id.not_nil!}, ctrl_comment_read)
  CanCan::ControllerResource.new(c, singleton: true).load_resource
  c.cancan_instance("comment").as(Comment).body.to_s
}
CASES["ctrl_authorize_show"] = -> {
  c = FakeCanCanController.new(ctrl_params_show, ctrl_read)
  CanCan::ControllerResource.new(c).load_and_authorize_resource
  c.cancan_instance("article").as(Article).title.to_s
}
CASES["ctrl_authorize_denied"] = -> {
  a = PlainAbility.new
  a.can :read, Comment
  c = FakeCanCanController.new(ctrl_params_show, a)
  begin
    CanCan::ControllerResource.new(c).load_and_authorize_resource
    "no_raise"
  rescue e
    "raise:#{e.class.name}"
  end
}
CASES["ctrl_authorize_index_class"] = -> {
  c = FakeCanCanController.new({"action" => "index", "controller" => "articles"}, ctrl_read)
  CanCan::ControllerResource.new(c).load_and_authorize_resource
  c.cancan_collection("articles").not_nil!.size.to_s
}
CASES["ctrl_authorize_parent_nested"] = -> {
  a = PlainAbility.new
  a.can :read, Comment, {"article" => {"published" => true}}
  c = FakeCanCanController.new({"action" => "show", "controller" => "comments"}, a)
  c.cancan_set_instance("article", ARTICLES[0])
  CanCan::ControllerResource.new(c, through: :article).authorize_resource
  "no_raise"
}
CASES["ctrl_authorize_parent_nested_denied"] = -> {
  a = PlainAbility.new
  a.can :read, Comment, {"article" => {"published" => true}}
  c = FakeCanCanController.new({"action" => "show", "controller" => "comments"}, a)
  c.cancan_set_instance("article", ARTICLES[1])
  begin
    CanCan::ControllerResource.new(c, through: :article).authorize_resource
    "no_raise"
  rescue e : CanCan::AccessDenied
    "raise:#{e.class.name}"
  end
}
CASES["ctrl_parent_authorization_action"] = -> {
  a = PlainAbility.new
  a.can :show, Comment
  a.cannot :update, Comment
  c = FakeCanCanController.new({"action" => "update", "controller" => "comments"}, a)
  c.cancan_set_instance("comment", C_HI)
  CanCan::ControllerResource.new(c, :comment, parent_flag: true).authorize_resource
  "no_raise"
}
CASES["ctrl_skip_load_only"] = -> {
  c = FakeCanCanController.new(ctrl_params_show, ctrl_read)
  c.cancan_skip("load", only: [:show])
  CanCan::ControllerResource.new(c).load_resource
  c.cancan_instance_defined?("article").to_s
}
CASES["ctrl_skip_load_other_action_loads"] = -> {
  c = FakeCanCanController.new(
    {"action" => "edit", "controller" => "articles", "id" => ARTICLES[0].id.not_nil!}, ctrl_read)
  c.cancan_skip("load", only: [:show])
  CanCan::ControllerResource.new(c).load_resource
  c.cancan_instance("article").as(Article).title.to_s
}
CASES["ctrl_skip_authorize"] = -> {
  a = PlainAbility.new
  a.can :read, Comment
  c = FakeCanCanController.new(ctrl_params_show, a)
  c.cancan_skip("authorize")
  CanCan::ControllerResource.new(c).load_and_authorize_resource
  c.cancan_instance("article").as(Article).title.to_s
}
CASES["ctrl_additions_can_helper"] = -> {
  c = FakeCanCanController.new({} of String => String, ctrl_read)
  [c.can?(:read, Article), c.can?(:update, Article)].inspect
}
CASES["ctrl_additions_authorized_flag"] = -> {
  a = PlainAbility.new
  a.can :read, Comment
  c = FakeCanCanController.new(ctrl_params_show, a)
  begin
    c.authorize!(:read, ARTICLES[0])
    "authorized"
  rescue e : CanCan::AccessDenied
    "denied:#{e.class.name}"
  end
}

# ============================================================================
# Controller additions, layer 2: ActionController integration (spec-only —
# the gem behavior itself is oracle-covered above; this checks the macro
# wiring: before-action registration, typed getters, params bridge).

class L2AbilityBox
  @@ability : CanCan::Ability? = nil

  def self.ability=(ability : CanCan::Ability) : Nil
    @@ability = ability
  end

  def self.ability : CanCan::Ability
    @@ability.not_nil!
  end
end

class L2ArticlesController < ActionController::Base
  load_and_authorize_resource :article, model: Article

  def current_ability : CanCan::Ability
    L2AbilityBox.ability
  end

  # the gem's `def article_params; params.require(:article).permit(:title); end`
  def cancan_permitted_params(name : String, action : String) : CanCan::ParamHash?
    return nil unless name == "article"
    p = params["article"]?.as?(ActionController::Parameters)
    return nil unless p
    CanCan.from_parameters_value(p.permit("title")).as?(Hash(String, CanCan::ParamValue))
  end

  def show
    render json: article.try(&.title).to_s
  end

  def index
    render json: (articles.try(&.map(&.title.to_s)) || [] of String).join(",")
  end

  def create
    render json: article.try(&.title).to_s
  end
end

def l2_dispatch(action : String, route_params : Hash(String, String), body : String? = nil)
  request = HTTP::Request.new(body ? "POST" : "GET", "/articles")
  if body
    request.headers["Content-Type"] = "application/json"
    request.body = IO::Memory.new(body)
  end
  io = IO::Memory.new
  context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
  controller = L2ArticlesController.new(context)
  controller.__set_params(route_params, "articles", action)
  controller.__run_action(action)
  context.response.close
  raw = io.to_s
  body = raw.includes?("\r\n\r\n") ? raw.split("\r\n\r\n", 2)[1].to_s : raw
  {controller, body}
end

def l2_read_ability : CanCan::Ability
  a = PlainAbility.new
  a.can :read, Article
  a
end

it "l2_show_loads_and_authorizes" do
  L2AbilityBox.ability = l2_read_ability
  controller, body = l2_dispatch("show", {"id" => ARTICLES[0].id.to_s})
  controller.as(L2ArticlesController).article.try(&.title).to_s.should eq("pub a")
  body.should eq("pub a")
end

it "l2_index_collection_accessibility" do
  a = PlainAbility.new
  a.can :read, Article, {"published" => true}
  L2AbilityBox.ability = a
  controller, body = l2_dispatch("index", {} of String => String)
  controller.as(L2ArticlesController).articles.not_nil!.size.should eq(2)
  body.should eq("pub a,pub c") # published only, id order: pub a (1), pub c (3)
end

it "l2_show_denied_raises_access_denied" do
  a = PlainAbility.new
  a.can :read, Comment
  L2AbilityBox.ability = a
  expect_raises(CanCan::AccessDenied) do
    l2_dispatch("show", {"id" => ARTICLES[0].id.to_s})
  end
end

it "l2_create_builds_from_json_params" do
  a = PlainAbility.new
  a.can :create, Article
  L2AbilityBox.ability = a
  controller, body = l2_dispatch("create", {} of String => String,
    body: %({"article": {"title": "l2 created"}}))
  controller.as(L2ArticlesController).article.try(&.title).to_s.should eq("l2 created")
  body.should eq("l2 created")
end
