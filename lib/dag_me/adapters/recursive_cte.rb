# frozen_string_literal: true

module DagMe
  module Adapters
    # Answers reachability by walking the edges table with WITH RECURSIVE.
    # No materialized state; suited to small graphs, high mutation rates,
    # and as the truth oracle when validating the closure adapter.
    class RecursiveCte < Base
      def ancestors(node)
        walk(node, from: config.edge_child_columns, to: config.edge_parent_columns)
      end

      def descendants(node)
        walk(node, from: config.edge_parent_columns, to: config.edge_child_columns)
      end

      def self_and_ancestors(node)
        ancestors(node).or(model.where(node_key(node)))
      end

      def self_and_descendants(node)
        descendants(node).or(model.where(node_key(node)))
      end

      def reachable?(ancestor, descendant)
        return false if same_node?(ancestor, descendant)

        descendants(ancestor).where(node_key(descendant)).exists?
      end

      def apply_topological_order(relation)
        cte, definition = reach_cte('up',
                                    from: config.edge_child_columns,
                                    to: config.edge_parent_columns) do |edge|
          config.edge_child_columns.zip(pk_columns)
                .map { |c, pk| edge[c].eq(model.arel_table[pk]) }.inject(:and)
        end
        count = cte.project(Arel.star.count).with(:recursive, definition)
        ordered_by(relation, count)
      end

      private

      def walk(node, from:, to:)
        cte, definition = reach_cte('walk', from: from, to: to) do |edge|
          from.zip(node_values(node)).map { |c, v| edge[c].eq(v) }.inject(:and)
        end
        reachable = cte.project(*pk_columns.map { |c| cte[c] })
                       .with(:recursive, definition)
        model.where(pk_tuple_in(reachable.ast))
      end

      # WITH RECURSIVE <name>(pk...) walking the edges table from `from`
      # towards `to`, seeded by the condition the block builds on the edge
      # table. Returns the CTE table and its definition.
      def reach_cte(name, from:, to:)
        edge = Arel::Table.new(config.edge_table)
        cte = Arel::Table.new(name)
        conn = model.connection
        base = edge.project(*to.zip(pk_columns).map { |c, pk| edge[c].as(conn.quote_column_name(pk)) })
                   .where(yield(edge))
        step = edge.project(*to.map { |c| edge[c] })
                   .join(cte).on(from.zip(pk_columns).map { |c, pk| edge[c].eq(cte[pk]) }.inject(:and))
        [cte, Arel::Nodes::As.new(cte, base.union(step))]
      end
    end
  end
end
