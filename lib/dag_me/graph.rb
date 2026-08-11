# frozen_string_literal: true

module DagMe
  # Class-level facade for graph-wide operations, reached via `Model.dag`
  # (default graph) or `Model.dag(:name)` (named graph):
  #
  #   Task.dag.between(a, b)
  #   Task.dag.edges_among(relation)
  #   Relay.dag(:power).rebuild!
  #   Task.dag.valid?
  #   Task.dag.validate!
  class Graph
    attr_reader :model, :config

    def initialize(model, config = nil)
      @model = model
      @config = config || model.dag_config
    end

    def adapter
      config.adapter
    end

    # Every node lying on some path from `ancestor` to `descendant`,
    # both endpoints included.
    def between(ancestor, descendant)
      adapter.between(ancestor, descendant)
    end

    def edges
      config.edge_class.all
    end

    # Edges whose both endpoints are inside the given node relation -
    # the induced subgraph's edge set (for exports, visualization, Kahn
    # walks in Ruby, ...).
    def edges_among(relation)
      edges = config.edge_class
      sub = relation.select(*config.node_pk_columns).arel.ast
      endpoint_in = lambda do |columns|
        tuple = Arel::Nodes::Grouping.new(columns.map { |c| edges.arel_table[c] })
        Arel::Nodes::In.new(tuple, sub)
      end
      edges.where(endpoint_in.call(config.edge_parent_columns))
           .where(endpoint_in.call(config.edge_child_columns))
    end

    # Rebuilds the closure table from the edges table. No-op for
    # maintain: :recursive_cte (there is nothing materialized).
    def rebuild!
      return self unless config.closure?

      model.connection_pool.with_connection do |conn|
        conn.execute("SELECT #{conn.quote_table_name(config.function_ref('rebuild_paths'))}();")
      end
      self
    end

    # Restores missing self-rows for nodes inserted with triggers disabled -
    # Rails fixture loading wraps inserts in disable_referential_integrity,
    # which skips the node_insert trigger. Idempotent; meant for test setups.
    def backfill_self_rows!
      return self unless config.closure?

      model.connection_pool.with_connection do |conn|
        conn.execute(DDL.new(config).backfill_self_rows_sql)
      end
      self
    end

    # Rows where the stored closure disagrees with the recursive-CTE truth.
    # Empty means healthy.
    def validate
      return [] unless config.closure?

      model.connection_pool.with_connection do |conn|
        conn.select_all("SELECT * FROM #{conn.quote_table_name(config.function_ref('validate_paths'))}();").to_a
      end
    end

    def valid?
      validate.empty?
    end

    def validate!
      rows = validate
      if rows.any?
        raise CorruptionError.new(
          "dag_me: closure for #{model.name} diverged from edge truth (#{rows.length} rows)", rows
        )
      end

      self
    end
  end
end
