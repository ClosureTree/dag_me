# frozen_string_literal: true

module DagMe
  class Configuration
    MAINTAIN_MODES = %i[postgresql_closure recursive_cte].freeze

    attr_reader :model, :name, :maintain, :prefix, :schema, :edge_table, :paths_table, :scope_columns

    def initialize(model:, name: nil, maintain: :postgresql_closure, scope: nil, prefix: nil,
                   edge_table: nil, paths_table: nil)
      unless MAINTAIN_MODES.include?(maintain)
        raise ArgumentError, "maintain must be one of #{MAINTAIN_MODES.inspect}, got #{maintain.inspect}"
      end

      @model = model
      @name = name&.to_sym
      @maintain = maintain
      @scope_columns = Array(scope).map(&:to_sym).freeze
      # Schema-qualified node tables ("ai.skills") keep the prefix a plain
      # identifier - trigger and temp-table names cannot carry a schema - and
      # place generated tables and functions in the node table's schema.
      @schema, base_table = split_schema(model.table_name)
      # A custom prefix keeps generated identifiers under PostgreSQL's 63-byte
      # limit when the derived one (long table names) would silently truncate.
      @prefix = prefix&.to_s || [base_table.singularize, @name, 'dag'].compact.join('_')
      validate_prefix!
      @edge_table = edge_table || qualify("#{@prefix}_edges")
      @paths_table = paths_table || qualify("#{@prefix}_paths")
      # Ivar peek keeps class load DB-free; composite keys must be declared
      # before the macro. Array === because AR seeds a BasicObject sentinel.
      @composite_pk = model.instance_variable_defined?(:@primary_key) &&
                      Array === model.instance_variable_get(:@primary_key) # rubocop:disable Style/CaseEquality
    end

    def closure?
      maintain == :postgresql_closure
    end

    # "skill_dag_edges" -> "ai.skill_dag_edges" when the node table lives in a
    # named schema; identity otherwise.
    def qualify(identifier)
      schema ? "#{schema}.#{identifier}" : identifier
    end

    # Schema-qualified reference for a generated function ("ai.skill_dag_lock").
    def function_ref(suffix)
      qualify("#{prefix}_#{suffix}")
    end

    # Trigger names are plain identifiers; placement comes from ON <table>.
    def trigger_name(suffix)
      "#{prefix}_#{suffix}"
    end

    # The unnamed dag from a bare `dag_me` call. Named dags come from
    # `dag_me :power` and get name-prefixed tables, constants, and
    # associations so several graphs can coexist on one model.
    def default?
      name.nil?
    end

    # Task::DagEdge for the default dag, Relay::PowerDagEdge for dag_me :power.
    def edge_class_name
      default? ? 'DagEdge' : "#{name.to_s.camelize}DagEdge"
    end

    def paths_class_name
      default? ? 'DagPath' : "#{name.to_s.camelize}DagPath"
    end

    def edge_class
      model.const_get(edge_class_name)
    end

    def paths_class
      model.const_get(paths_class_name)
    end

    # children / power_children, dag_child_edges / power_dag_child_edges, ...
    def association_name(base)
      default? ? base.to_sym : :"#{name}_#{base}"
    end

    def composite_pk?
      @composite_pk
    end

    def node_table
      model.table_name
    end

    # Node identity as an ordered column list. Single-key models yield one
    # column and everything downstream degenerates to the classic layout.
    def node_pk_columns
      @node_pk_columns ||= if composite_pk?
                             model.primary_key.map(&:to_s).freeze
                           else
                             pk = model.primary_key
                             if pk.is_a?(Array)
                               raise ArgumentError,
                                     "#{model.name}: declare `self.primary_key = [...]` before calling dag_me"
                             end
                             [pk.to_s].freeze
                           end
    end

    # Graph column names, one per pk column. Single-key models keep the
    # classic parent_id / child_id / ancestor_id / descendant_id regardless
    # of the pk's actual name; composite keys suffix each key column.
    def edge_parent_columns
      @edge_parent_columns ||= role_columns('parent')
    end

    def edge_child_columns
      @edge_child_columns ||= role_columns('child')
    end

    def paths_ancestor_columns
      @paths_ancestor_columns ||= role_columns('ancestor')
    end

    def paths_descendant_columns
      @paths_descendant_columns ||= role_columns('descendant')
    end

    def node_pk_type(column)
      model.columns_hash.fetch(column.to_s).sql_type
    end

    def scope_column_type(column)
      model.columns_hash.fetch(column.to_s).sql_type
    end

    def adapter
      @adapter ||= if closure?
                     Adapters::PostgresqlClosure.new(self)
                   else
                     Adapters::RecursiveCte.new(self)
                   end
    end

    private

    # The longest generated suffix is "_edge_insert_check" (18 bytes); reject
    # prefixes whose identifiers PostgreSQL would silently truncate at 63.
    def validate_prefix!
      unless /\A[a-z_][a-z0-9_]*\z/.match?(@prefix)
        raise ArgumentError, "prefix must be a lowercase SQL identifier, got #{@prefix.inspect}"
      end

      max = 63 - '_edge_insert_check'.length
      return if @prefix.length <= max

      raise ArgumentError,
            "prefix #{@prefix.inspect} is #{@prefix.length} bytes; identifiers would exceed " \
            "PostgreSQL's 63-byte limit (max prefix: #{max}). Pass dag_me prefix: '...' with a shorter name."
    end

    def split_schema(table_name)
      return table_name.split('.', 2) if table_name.include?('.')

      [nil, table_name]
    end

    def role_columns(role)
      return ["#{role}_id"].freeze unless composite_pk?

      node_pk_columns.map { |c| "#{role}_#{c}" }.freeze
    end
  end
end
