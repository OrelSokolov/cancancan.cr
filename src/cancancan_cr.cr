# cancancan_cr — port of CanCanCan 3.6.1 core (Ability + Rule + conditions
# matching + accessible_by) to Crystal over active_record_cr.
#
# The Ruby gem exposes a module (CanCan::Ability) to include into an
# ability class; the same shape is kept here. Oracle: oracle/cases.rb
# over the original gem.

require "active_record_cr"

module CanCan
  class Error < Exception; end

  class AccessDenied < Error
    getter action : Symbol
    getter subject : Subject

    def initialize(message : String, @action : Symbol, @subject : Subject)
      super(message)
    end
  end

  class BlockAndConditionsError < Error; end

  # A relation passed as rule conditions (the gem's `can :read, Article,
  # Article.where(...)` scope form). Crystal cannot union Relation(T) over
  # all models, so the query-facing parts are captured up front.
  struct RawScope
    getter fragments : Array({String, Array(DB::Any)})
    getter where_values_hash : Hash(String, ActiveRecord::Value)

    def initialize(rel : ActiveRecord::Relation)
      @fragments = rel.where_values
      @where_values_hash = rel.where_values_hash
    end

    # The gem's catch-all test for scopes: `where_values_hash.empty?`.
    def blank? : Bool
      @where_values_hash.empty?
    end

    def empty? : Bool
      @fragments.empty?
    end

    def ==(other : RawScope) : Bool
      @fragments == other.fragments && @where_values_hash == other.where_values_hash
    end
  end

  # A subject: :all / any Symbol / String, an AR class, or an instance.
  alias Subject = Symbol | String | ActiveRecord::Base.class | ActiveRecord::Base | Nil

  # Values allowed inside a conditions hash (recursively).
  alias CondVal = Nil | Bool | Int64 | Float64 | String |
                  Array(Int64 | String) | Range(Int64, Int64) |
                  Hash(String, CondVal) | RawScope

  # What `record.cancan_attribute(name)` may return (a column value,
  # an association collection, or a single associated record).
  alias CondAttr = ActiveRecord::Value | Array(ActiveRecord::Base) |
                   ActiveRecord::Base | Nil

  # Subjects handed to `can` blocks.
  alias BlockSubject = Symbol | String | ActiveRecord::Base

  # The (action, object_class, object) triple handed to a catch-all block.
  alias CatchAllClass = Symbol | String | ActiveRecord::Base.class

  DEFAULT_ALIASES = {
    :read   => [:index, :show],
    :create => [:new],
    :update => [:edit],
  } of Symbol => Array(Symbol)

  # Converts a user-written conditions literal (Hash(String, Bool) etc.)
  # into Hash(String, CondVal) — Crystal generics are invariant.
  def self.to_cond(h : Hash) : Hash(String, CondVal)
    r = {} of String => CondVal
    h.each { |k, v| r[k.to_s] = to_cond_val(v) }
    r
  end

  def self.to_cond_val(v) : CondVal
    case v
    when Hash then to_cond(v)
    when Range
      Range.new(v.begin.as(Int64), v.end.as(Int64), v.excludes_end?)
    when Array
      v.map { |e| e.as(Int64 | String) }
    else
      v.as(CondVal)
    end
  end

  def self.conds_eq(a : CondVal, b : CondVal) : Bool
    case a
    when Hash(String, CondVal)
      b.is_a?(Hash(String, CondVal)) && a == b
    when RawScope
      b.is_a?(RawScope) && a == b
    when Nil
      b.nil?
    else
      a == b
    end
  end

  # --- Rule (lib/cancan/rule.rb + conditions_matcher + relevant) ----------

  class Rule
    getter base_behavior : Bool
    getter actions : Array(Symbol)
    getter subjects : Array(Subject)
    getter attributes : Array(Symbol)
    getter conditions : CondVal
    getter block : Proc(BlockSubject, Bool)?
    getter attr_block : Proc(BlockSubject, Symbol?, Bool)?
    getter catch_all_block : Proc(Symbol, CatchAllClass, ActiveRecord::Base | Nil, Bool)?
    getter? match_all : Bool

    @expanded_actions : Array(Symbol) = [] of Symbol

    def initialize(@base_behavior : Bool, actions : Symbol | Array(Symbol) | Nil,
                   subjects : Subject | Array(Subject) | Nil,
                   attributes : Array(Symbol) | Nil = nil,
                   conditions : CondVal = nil,
                   block : Proc(BlockSubject, Bool)? = nil,
                   catch_all_block : Proc(Symbol, CatchAllClass, ActiveRecord::Base | Nil, Bool)? = nil,
                   attr_block : Proc(BlockSubject, Symbol?, Bool)? = nil)
      @match_all = actions.nil? && subjects.nil?
      raise Error.new("Subject is required for #{actions}") if actions && subjects.nil?

      @actions = actions.is_a?(Array(Symbol)) ? actions : (actions ? [actions.not_nil!] : [] of Symbol)
      if subjects.is_a?(Array(Subject))
        @subjects = subjects
      elsif s = subjects
        @subjects = [s] of Subject
      else
        @subjects = [] of Subject
      end
      @attributes = attributes || [] of Symbol
      @conditions = conditions || nil
      @block = block
      @catch_all_block = catch_all_block
      @attr_block = attr_block
    end

    def can_rule? : Bool
      @base_behavior
    end

    # The gem's catch_all?: blank conditions (nil / empty hash / empty
    # scope) match everything.
    def catch_all? : Bool
      case c = @conditions
      when RawScope              then c.blank?
      when Hash(String, CondVal) then c.empty?
      when String                then c.blank?
      when Nil                   then true
      else
        false
      end
    end

    def cannot_catch_all? : Bool
      !can_rule? && catch_all?
    end

    def only_block? : Bool
      return false unless conditions_empty?
      !@block.nil? || !@attr_block.nil? || !@catch_all_block.nil?
    end

    def only_raw_sql? : Bool
      @block.nil? && @attr_block.nil? && @catch_all_block.nil? &&
        !conditions_empty? && !@conditions.is_a?(Hash)
    end

    def expanded_actions=(actions : Array(Symbol))
      @expanded_actions = actions
    end

    def attributes_from_conditions : Hash(String, CondVal)
      attrs = {} of String => CondVal
      if (c = @conditions).is_a?(Hash(String, CondVal))
        c.each do |k, v|
          attrs[k] = v unless v.is_a?(Array) || v.is_a?(Range) || v.is_a?(Hash)
        end
      end
      attrs
    end

    def matches_attributes?(attribute : Symbol?) : Bool
      return true if @attributes.empty?
      return @base_behavior if attribute.nil?
      @attributes.includes?(attribute)
    end

    # Gem Rule#inspect: `#<CanCan::Rulecan [:read], [Article(id: integer,
    # ...)], [:title], {}>` (subjects render through Model.inspect).
    def inspect : String
      repr = "#<CanCan::Rule#{@base_behavior ? "can" : "cannot"} #{@actions.inspect}, " \
             "[#{@subjects.map { |s| s.inspect }.join(", ")}], #{@attributes.inspect}"
      repr += ", #{conditions_repr}" unless @conditions.is_a?(RawScope)
      repr + ">"
    end

    private def conditions_repr : String
      case c = @conditions
      when Hash(String, CondVal)
        "{" + c.map { |k, v| "#{k}: #{cond_val_repr(v)}" }.join(", ") + "}"
      when String then c.inspect
      else
        "{}"
      end
    end

    private def cond_val_repr(v : CondVal) : String
      case v
      when Hash(String, CondVal)
        "{" + v.map { |k, vv| "#{k}: #{cond_val_repr(vv)}" }.join(", ") + "}"
      else
        v.inspect
      end
    end

    # --- Relevant ---
    def relevant?(action : Symbol, subject : Subject) : Bool
      subject = nested_subject(subject)
      @match_all || (matches_action?(action) && matches_subject?(subject))
    end

    def matches_action?(action : Symbol) : Bool
      @expanded_actions.includes?(:manage) || @expanded_actions.includes?(action)
    end

    def matches_subject?(subject : Subject) : Bool
      return true if @subjects.includes?(:all)
      case subject
      when Symbol, String
        @subjects.includes?(subject)
      when ActiveRecord::Base.class
        @subjects.any? do |s|
          s.is_a?(ActiveRecord::Base.class) && (s == subject || subject < s)
        end
      when ActiveRecord::Base
        @subjects.any? do |s|
          s.is_a?(ActiveRecord::Base.class) && (s === subject)
        end
      else
        false
      end
    end

    # --- ConditionsMatcher ---
    def matches_conditions?(action : Symbol, subject : Subject,
                            attribute : Symbol? = nil) : Bool
      if @match_all
        return call_catch_all_block(action, subject)
      end
      if ablock = @attr_block
        return @base_behavior if subject_class?(subject)
        case subject
        when ActiveRecord::Base, Symbol, String
          return ablock.call(subject, attribute)
        else
          return @base_behavior
        end
      end
      if block = @block
        return @base_behavior if subject_class?(subject)
        case subject
        when ActiveRecord::Base, Symbol, String
          return block.call(subject)
        else
          return @base_behavior
        end
      end
      return true if conditions_empty?
      case subject
      when Symbol, String, ActiveRecord::Base.class
        # Don't stop at "cannot" definitions when there are conditions.
        @base_behavior
      when ActiveRecord::Base
        matches_conditions_hash?(subject, @conditions)
      else
        @base_behavior
      end
    end

    # Nested subject (`can? :read, parent => child` in the gem): the child
    # class drives relevance; conditions are matched against the PARENT
    # through the belongs_to association name, plus the foreign-key
    # condition check against parent.id (AR adapter semantics).
    def matches_conditions_nested?(action : Symbol, parent : ActiveRecord::Base,
                                   child : Subject) : Bool
      return @base_behavior if @match_all || @block || @attr_block
      return true if conditions_empty?
      conds = @conditions.as?(Hash(String, CondVal)) || {} of String => CondVal
      spec = parent_belongs_to_spec(parent, child)
      # gem fallback: parent class name downcased ("Article" → "article")
      parent_name = spec ? spec[:name] : (parent.class.name || parent.class.to_s).downcase
      parent_conds = conds[parent_name]? || {} of String => CondVal
      return false unless matches_conditions_hash?(parent, parent_conds)
      if spec && (fk = conds[spec[:foreign_key]]?)
        case fk
        when Array(Int64 | String)
          (pid = parent.id) ? fk.any? { |v| v == pid } : false
        when Int64
          fk == parent.id
        else
          false
        end
      else
        true
      end
    end

    def call_catch_all_block(action : Symbol, subject : Subject) : Bool
      if block = @catch_all_block
        case subject
        when ActiveRecord::Base.class
          block.call(action, subject, nil)
        when ActiveRecord::Base
          block.call(action, subject.class, subject)
        else
          block.call(action, subject.as(CatchAllClass), nil)
        end
      else
        true
      end
    end

    def subject_class?(subject : Subject) : Bool
      subject.is_a?(ActiveRecord::Base.class) || subject.is_a?(Symbol) || subject.is_a?(String)
    end

    def conditions_empty? : Bool
      (c = @conditions).nil? || (c.is_a?(Hash(String, CondVal)) && c.empty?)
    end

    def matches_conditions_hash?(subject : ActiveRecord::Base, conditions : CondVal) : Bool
      return true if conditions.is_a?(Hash(String, CondVal)) && conditions.empty?
      return false unless conditions.is_a?(Hash(String, CondVal))

      conditions.all? do |name, value|
        condition_match?(subject.cancan_attribute(name), value)
      end
    end

    def condition_match?(attr : CondAttr, value : CondVal) : Bool
      case value
      when Hash(String, CondVal)
        case attr
        when Array(ActiveRecord::Base)
          if attr.any?
            attr.any? { |el| matches_conditions_hash?(el, value) }
          else
            # nil-valued children express "no children at all"
            !value.values.empty? && value.values.all?(&.nil?)
          end
        when ActiveRecord::Base
          matches_conditions_hash?(attr, value)
        else
          false
        end
      when Range(Int64, Int64)
        attr.is_a?(Int64) && value.covers?(attr)
      when Array(Int64 | String)
        attr.is_a?(ActiveRecord::Value) && value.any? { |v| v == attr }
      else
        attr.is_a?(ActiveRecord::Value) && value == attr
      end
    end

    private def nested_subject(subject : Subject) : Subject
      subject
    end

    private def parent_belongs_to_spec(parent : ActiveRecord::Base, child : Subject)
      klass = case child
              when ActiveRecord::Base.class then child
              when ActiveRecord::Base       then child.class
              else
                nil
              end
      return nil unless klass
      # Class-level codegen methods (per-model) are unreachable from the
      # static Base.class type — dispatch through the registered-model
      # helpers; unregistered models fall back to the class-name path.
      specs = CanCan.class_assoc_specs?(klass)
      parent_table = CanCan.class_table_name?(parent.class)
      return nil if specs.nil? || parent_table.nil?
      specs.find do |s|
        s[:kind] == "belongs_to" && s[:table] == parent_table
      end
    end
  end

  # --- RulesCompressor (lib/cancan/rules_compressor.rb) ---------------------

  module RulesCompressor
    # `rules` in definition order.
    def self.compress(rules : Array(Rule)) : Array(Rule)
      simplified = simplify(rules)
      idx = simplified.rindex(&.catch_all?)
      return simplified unless idx
      value = simplified[idx]
      i = idx
      while i < simplified.size && simplified[i].base_behavior == value.base_behavior
        i += 1
      end
      dropped = [] of Rule
      while i < simplified.size
        dropped << simplified[i]
        i += 1
      end
      dropped.unshift(value) unless value.cannot_catch_all?
      dropped
    end

    # Dedupe by conditions keeping the last-defined of each (gem simplify).
    private def self.simplify(rules : Array(Rule)) : Array(Rule)
      seen = [] of CondVal
      kept = [] of Rule
      rules.reverse_each do |rule|
        next if seen.any? { |c| CanCan.conds_eq(c, rule.conditions) }
        seen << rule.conditions
        kept << rule
      end
      kept.reverse
    end
  end

  # --- SQL fragment builder (conditions_extractor + adapter merge) ----------

  # Renders one rule's conditions as a self-contained WHERE fragment
  # (literals inlined, strings escaped). nil for blank conditions (matches
  # everything).
  def self.rule_fragment(model : ActiveRecord::Base.class,
                         conditions : CondVal) : String?
    case conditions
    when Hash(String, CondVal)
      return nil if conditions.empty?
      hash_fragment(model.table_name, model.primary_key,
        model.__assoc_specs, conditions)
    when String
      return nil if conditions.blank?
      conditions
    when RawScope
      return nil if conditions.empty?
      conditions.fragments.map { |f, a| inline(f, a) }.join(" AND ")
    else
      nil
    end
  end

  # Hash conditions → AND-ed SQL. Nested hashes become (NOT) EXISTS
  # subqueries through the association join (same result sets as the
  # gem's LEFT JOIN aliasing).
  def self.hash_fragment(table : String, pk : String,
                         specs : Array(ActiveRecord::AssocSpec),
                         conds : Hash(String, CondVal)) : String?
    return nil if conds.empty?
    frags = [] of String
    conds.each do |name, value|
      if (nested = value.as?(Hash(String, CondVal)))
        spec = specs.find { |s| s[:name] == name }
        raise Error.new("Association '#{name}' not defined in model '#{table}'") unless spec
        join = spec[:kind] == "has_many" ? %("#{spec[:table]}"."#{spec[:foreign_key]}" = "#{table}"."#{pk}") : %("#{spec[:table]}"."#{spec[:pk]}" = "#{table}"."#{spec[:foreign_key]}")
        if !nested.empty? && nested.all? { |_, v| v.nil? }
          # {assoc: {id: nil}} — no children at all
          frags << %(NOT EXISTS (SELECT 1 FROM "#{spec[:table]}" WHERE #{join}))
        else
          inner = hash_fragment(spec[:table], spec[:pk],
            ActiveRecord.__assoc_specs_by_table(spec[:table]), nested).not_nil!
          frags << %(EXISTS (SELECT 1 FROM "#{spec[:table]}" WHERE #{join} AND (#{inner})))
        end
      else
        col = %("#{table}"."#{name}")
        case value
        when Nil
          frags << %(#{col} IS NULL)
        when Array(Int64 | String)
          frags << %(#{col} IN (#{value.map { |v| lit(v) }.join(", ")}))
        when Range(Int64, Int64)
          high = value.excludes_end? ? value.end - 1 : value.end
          frags << %(#{col} BETWEEN #{lit(value.begin)} AND #{lit(high)})
        else
          frags << %(#{col} = #{lit(value)})
        end
      end
    end
    frags.join(" AND ")
  end

  # SQL literal for a condition value (strings escaped by doubling quotes).
  def self.lit(v) : String
    case v
    when Nil     then "NULL"
    when Bool    then v ? "TRUE" : "FALSE"
    when Int64   then v.to_s
    when Float64 then v.to_s
    when String  then "'" + v.gsub("'", "''") + "'"
    else
      "'" + v.to_s.gsub("'", "''") + "'"
    end
  end

  # Substitutes a fragment's `?` placeholders with inlined literals.
  def self.inline(fragment : String, args : Array(DB::Any)) : String
    idx = -1
    fragment.gsub("?") do
      idx += 1
      lit(args[idx]?)
    end
  end

  # --- Ability (lib/cancan/ability.rb + actions + rules) -------------------

  module Ability
    @rules = [] of Rule
    @aliased_actions : Hash(Symbol, Array(Symbol))? = nil

    protected def rules : Array(Rule)
      @rules
    end

    def can(action : Symbol? = nil, subject : Subject? = nil) : Nil
      add_rule(Rule.new(true, action, subject))
    end

    def cannot(action : Symbol? = nil, subject : Subject? = nil) : Nil
      add_rule(Rule.new(false, action, subject))
    end

    def can(actions : Array(Symbol), subject : Subject | Array(Subject)) : Nil
      add_rule(Rule.new(true, actions, subject))
    end

    def cannot(actions : Array(Symbol), subject : Subject | Array(Subject)) : Nil
      add_rule(Rule.new(false, actions, subject))
    end

    def can(action : Symbol, subjects : Array(Subject)) : Nil
      add_rule(Rule.new(true, action, subjects))
    end

    def cannot(action : Symbol, subjects : Array(Subject)) : Nil
      add_rule(Rule.new(false, action, subjects))
    end

    def can(action : Symbol, subject : Subject, conditions : Hash) : Nil
      add_rule(Rule.new(true, action, subject, conditions: CanCan.to_cond(conditions)))
    end

    def can(action : Symbol, subject : Subject, raw_sql : String) : Nil
      add_rule(Rule.new(true, action, subject, conditions: raw_sql))
    end

    def can(action : Symbol, subject : Subject, scope : ActiveRecord::Relation) : Nil
      add_rule(Rule.new(true, action, subject, conditions: RawScope.new(scope)))
    end

    def can(action : Symbol, subject : Subject, attributes : Array(Symbol),
            conditions : Hash | Nil = nil) : Nil
      if conditions
        raise BlockAndConditionsError.new(
          "A hash of conditions is mutually exclusive with a block. Check \":#{action} #{subject}\" ability.")
      end
      add_rule(Rule.new(true, action, subject, attributes: attributes))
    end

    def can(action : Symbol, subject : Subject, attribute : Symbol) : Nil
      add_rule(Rule.new(true, action, subject, attributes: [attribute]))
    end

    def cannot(action : Symbol, subject : Subject, conditions : Hash) : Nil
      add_rule(Rule.new(false, action, subject, conditions: CanCan.to_cond(conditions)))
    end

    def cannot(action : Symbol, subject : Subject, raw_sql : String) : Nil
      add_rule(Rule.new(false, action, subject, conditions: raw_sql))
    end

    def cannot(action : Symbol, subject : Subject, scope : ActiveRecord::Relation) : Nil
      add_rule(Rule.new(false, action, subject, conditions: RawScope.new(scope)))
    end

    def cannot(action : Symbol, subject : Subject, attributes : Array(Symbol),
               conditions : Hash | Nil = nil) : Nil
      add_rule(Rule.new(false, action, subject, attributes: attributes))
    end

    def cannot(action : Symbol, subject : Subject, attribute : Symbol) : Nil
      add_rule(Rule.new(false, action, subject, attributes: [attribute]))
    end

    def can(action : Symbol, subject : Subject, &block : Proc(BlockSubject, Bool)) : Nil
      add_rule(Rule.new(true, action, subject, block: block))
    end

    def cannot(action : Symbol, subject : Subject, &block : Proc(BlockSubject, Bool)) : Nil
      add_rule(Rule.new(false, action, subject, block: block))
    end

    # Block also receiving the checked attribute (gem's two-argument block).
    def can(action : Symbol, subject : Subject, &block : Proc(BlockSubject, Symbol?, Bool)) : Nil
      add_rule(Rule.new(true, action, subject, attr_block: block))
    end

    def cannot(action : Symbol, subject : Subject, &block : Proc(BlockSubject, Symbol?, Bool)) : Nil
      add_rule(Rule.new(false, action, subject, attr_block: block))
    end

    def can(&block : Proc(Symbol, CatchAllClass, ActiveRecord::Base | Nil, Bool)) : Nil
      add_rule(Rule.new(true, nil, nil, catch_all_block: block))
    end

    def cannot(&block : Proc(Symbol, CatchAllClass, ActiveRecord::Base | Nil, Bool)) : Nil
      add_rule(Rule.new(false, nil, nil, catch_all_block: block))
    end

    def can?(action : Symbol, subject : Subject, attribute : Symbol? = nil) : Bool
      relevant = relevant_rules(action, subject)
      relevant.each { |rule| raise raw_sql_error(action, subject) if rule.only_raw_sql? }
      match = relevant.find do |rule|
        rule.matches_conditions?(action, subject, attribute) && rule.matches_attributes?(attribute)
      end
      match ? match.base_behavior : false
    end

    # {any: [subjects]} — true if any subject has a matching rule (the
    # first matched rule wins, can or cannot).
    def can?(action : Symbol, *, any : Array(Subject), attribute : Symbol? = nil) : Bool
      any.each do |subject|
        relevant = relevant_rules(action, subject)
        relevant.each { |rule| raise raw_sql_error(action, subject) if rule.only_raw_sql? }
        match = relevant.find do |rule|
          rule.matches_conditions?(action, subject, attribute) && rule.matches_attributes?(attribute)
        end
        return match.base_behavior if match
      end
      false
    end

    # Nested subject (the gem's `{parent => child}` hash): conditions
    # involving the parent association are checked against the parent.
    def can?(action : Symbol, *, parent : ActiveRecord::Base, child : Subject,
             attribute : Symbol? = nil) : Bool
      relevant = relevant_rules(action, child)
      relevant.each { |rule| raise raw_sql_error(action, child) if rule.only_raw_sql? }
      match = relevant.find do |rule|
        rule.matches_conditions_nested?(action, parent, child) && rule.matches_attributes?(attribute)
      end
      match ? match.base_behavior : false
    end

    def cannot?(action : Symbol, subject : Subject, attribute : Symbol? = nil) : Bool
      !can?(action, subject, attribute)
    end

    def authorize!(action : Symbol, subject : Subject, message : String? = nil) : Subject
      if cannot?(action, subject)
        raise AccessDenied.new(message || "You are not authorized to access this page.", action, subject)
      end
      subject
    end

    def attributes_for(action : Symbol, subject : Subject) : Hash(String, CondVal)
      attributes = {} of String => CondVal
      relevant_rules(action, subject).each do |rule|
        attributes.merge!(rule.attributes_from_conditions) if rule.can_rule?
      end
      attributes
    end

    # Attributes permitted for strong parameters: reversed relevant rules
    # add (can) / remove (cannot); a rule without attribute restrictions
    # permits every column. Returns Array(String) — Crystal has no runtime
    # String#to_sym (documented deviation from the gem's symbol array).
    def permitted_attributes(action : Symbol, subject : Subject) : Array(String)
      permitted = [] of String
      relevant_rules(action, subject).reverse.each do |rule|
        next unless rule.matches_conditions?(action, subject)
        attrs = permitted_rule_attributes(rule, subject)
        if rule.can_rule?
          attrs.each { |a| permitted << a unless permitted.includes?(a) }
        else
          permitted.reject! { |a| attrs.includes?(a) }
        end
      end
      permitted
    end

    private def permitted_rule_attributes(rule : Rule, subject : Subject) : Array(String)
      return rule.attributes.map(&.to_s) unless rule.attributes.empty?
      klass = case subject
              when ActiveRecord::Base.class then subject
              when ActiveRecord::Base       then subject.class
              else
                return [] of String
              end
      klass.__column_names.map(&.to_s)
    end

    # No configured messages / i18n in the port — always the default
    # (kept as a seam mirroring the gem's UnauthorizedMessageResolver).
    def unauthorized_message(action : Symbol, subject : Subject) : String?
      nil
    end

    def has_block?(action : Symbol, subject : Subject) : Bool
      relevant_rules(action, subject).any?(&.only_block?)
    end

    def has_raw_sql?(action : Symbol, subject : Subject) : Bool
      relevant_rules(action, subject).any?(&.only_raw_sql?)
    end

    def merge(other : Ability) : self
      other.rules.each { |rule| add_rule(rule) }
      @aliased_actions = aliased_actions.merge(other.aliased_actions)
      self
    end

    # permissions (mirror of ability.rb): renders the same nested hash
    # string the gem's Hash#inspect produces.
    def permissions : String
      can_hash = {} of Symbol => Array({String, Array(Symbol)})
      cannot_hash = {} of Symbol => Array({String, Array(Symbol)})
      rules.each do |rule|
        container = rule.can_rule? ? can_hash : cannot_hash
        expand_actions(rule.actions).each do |action|
          rule.subjects.each do |subject|
            entry = {subject.to_s, rule.attributes}
            container[action] ||= [] of {String, Array(Symbol)}
            container[action] << entry
          end
        end
      end
      render = ->(h : Hash(Symbol, Array({String, Array(Symbol)}))) do
        inner = h.map do |action, entries|
          merged = {} of String => Array(Symbol)
          entries.each { |s, attrs| merged[s] = (merged[s]? || [] of Symbol) + attrs }
          subjects = merged.map { |s, attrs| %("#{s}" => [#{attrs.map(&.to_s).join(", ")}]) }
          "#{action}: {#{subjects.join(", ")}}"
        end
        "{#{inner.join(", ")}}"
      end
      "{can: #{render.call(can_hash)}, cannot: #{render.call(cannot_hash)}}"
    end

    # --- actions ---
    def alias_action(*args : Symbol, to : Symbol) : Array(Symbol)
      if aliased_actions.values.any? { |actions| actions.includes?(to) }
        raise Error.new(
          "You can't specify target (#{to}) as alias because it is real action name")
      end
      aliased_actions[to] ||= [] of Symbol
      aliased_actions[to] += args.to_a
    end

    def aliased_actions : Hash(Symbol, Array(Symbol))
      (@aliased_actions ||= DEFAULT_ALIASES.dup).not_nil!
    end

    def clear_aliased_actions : Nil
      @aliased_actions = {} of Symbol => Array(Symbol)
    end

    def expand_actions(actions : Array(Symbol)) : Array(Symbol)
      expanded = [] of Symbol
      actions.each do |action|
        expanded << action
        if (aliases = aliased_actions[action]?)
          expanded += expand_actions(aliases)
        end
      end
      expanded
    end

    # relevant rules in evaluation order (last defined first, deduped) —
    # mirrors rules.rb reverse+uniq.
    def relevant_rules(action : Symbol, subject : Subject) : Array(Rule)
      relevant = rules.select do |rule|
        rule.expanded_actions = expand_actions(rule.actions)
        rule.relevant?(action, subject)
      end
      relevant.reverse.uniq
    end

    def relevant_rules_for_query(action : Symbol, subject : Subject) : Array(Rule)
      relevant = relevant_rules(action, subject).reject do |rule|
        !rule.can_rule? && !rule.attributes.empty?
      end
      if relevant.any?(&.only_block?)
        raise Error.new(
          "The accessible_by call cannot be used with a block 'can' definition." \
          "The SQL cannot be determined for #{action.inspect} #{subject.inspect}")
      end
      relevant
    end

    private def add_rule(rule : Rule)
      rules << rule
    end

    private def raw_sql_error(action : Symbol, subject : Subject) : Error
      Error.new(
        "The can? and cannot? call cannot be used with a raw sql 'can' definition. " \
        "The checking code cannot be determined for #{action.inspect} #{subject.inspect}")
    end
  end

  # --- accessible_by (model_additions + AR adapter subset) ------------------
  # Mirrors the gem's adapter: rules compression, scope override, single
  # can rule fast path, and the AND/OR/NOT fold for multiple rules. Nested
  # hash conditions become (NOT) EXISTS subqueries (same result sets as
  # the gem's LEFT JOIN + aliasing).

  module AccessibleBy
    def accessible_by(ability, action : Symbol = :index)
      model = self
      rules = ability.relevant_rules_for_query(action, model)

      # definition order → compress → back to last-defined-first
      compressed = RulesCompressor.compress(rules.reverse).reverse

      # scope (Relation) conditions override everything else (gem
      # override_scope); merging a scope with other conditions raises.
      if compressed.any? { |r| r.conditions.is_a?(RawScope) }
        non_nil = compressed.reject { |r| r.conditions.nil? }
        if non_nil.size == 1 && (scope = non_nil.first.conditions).is_a?(RawScope)
          frag = CanCan.rule_fragment(model, scope)
          return frag ? model.where(frag) : model.all
        end
        rule_found = compressed.find { |r| r.conditions.is_a?(RawScope) }.not_nil!
        raise Error.new(
          "Unable to merge an Active Record scope with other conditions. " \
          "Instead use a hash or SQL for #{rule_found.actions.first.inspect} " \
          "#{rule_found.subjects.first.inspect} ability.")
      end

      # single can definition → its conditions verbatim
      if compressed.size == 1 && compressed.first.can_rule?
        if (frag = CanCan.rule_fragment(model, compressed.first.conditions))
          return model.where(frag)
        end
        return model.all
      end

      # fold rules in definition order: TRUE / FALSE sentinels + OR / NOT
      state = 0 # 0 = false, 1 = true, 2 = sql
      sql = ""
      compressed.reverse.each do |rule|
        frag = CanCan.rule_fragment(model, rule.conditions)
        if frag.nil?
          state = rule.can_rule? ? 1 : 0
          next
        end
        case state
        when 1
          unless rule.can_rule?
            state = 2
            sql = "NOT (#{frag})"
          end
        when 0
          if rule.can_rule?
            state = 2
            sql = frag
          end
        else
          sql = rule.can_rule? ? "(#{frag}) OR (#{sql})" : "NOT (#{frag}) AND (#{sql})"
        end
      end
      case state
      when 1 then model.all
      when 0 then model.none
      else
        model.where(sql)
      end
    end
  end
end

class ActiveRecord::Base
  # Attribute/association seam used by conditions matching. The default
  # only exists for the override chain: `[]` is generated per subclass,
  # so concrete models expose columns/associations by overriding (the
  # oracle spec's Article does).
  def cancan_attribute(name : String) : CanCan::CondAttr
    raise NotImplementedError.new("#{self.class} must override cancan_attribute")
  end
end

module ActiveRecord
  class Base
    extend CanCan::AccessibleBy
  end
end

require "./controller_additions"
