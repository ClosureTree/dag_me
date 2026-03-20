# frozen_string_literal: true

module DagMe
  class Configuration
    MAINTAIN_MODES = %i[postgresql_closure recursive_cte].freeze

    attr_reader :model, :name, :maintain, :prefix, :edge_table, :paths_table, :scope_columns

    def initialize(model:, name: nil, maintain: :postgresql_closure, scope: nil, edge_table: nil, paths_table: nil)
      unless MAINTAIN_MODES.include?(maintain)
        raise ArgumentError, "maintain must be one of #{MAINTAIN_MODES.inspect}, got #{maintain.inspect}"
      end

      @model = model
      @name = name&.to_sym
      @maintain = maintain
      @scope_columns = Array(scope).map(&:to_sym).freeze
      @prefix = [model.table_name.singularize, @name, 'dag'].compact.join('_')
      @edge_table = edge_table || "#{prefix}_edges"
      @paths_table = paths_table || "#{prefix}_paths"
      # Ivar peek keeps class load DB-free; composite keys must be declared
      # before the macro. Array === because AR seeds a BasicObject sentinel.
      @composite_pk = model.instance_variable_defined?(:@primary_key) &&
                      Array === model.instance_variable_get(:@primary_key) # rubocop:disable Style/CaseEquality
    end

    def closure?
      maintain == :postgresql_closure
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

    def role_columns(role)
      return ["#{role}_id"].freeze unless composite_pk?

      node_pk_columns.map { |c| "#{role}_#{c}" }.freeze
    end
  end
end
