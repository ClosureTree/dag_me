# frozen_string_literal: true

module DagMe
  module Adapters
    # Answers reachability from the trigger-maintained closure table.
    # Every query is a plain index join; no recursion at read time.
    class PostgresqlClosure < Base
      def ancestors(node)
        self_and_ancestors(node).where.not(node_key(node))
      end

      def descendants(node)
        self_and_descendants(node).where.not(node_key(node))
      end

      def self_and_ancestors(node)
        reach(node, select_cols: config.paths_ancestor_columns,
                    match_cols: config.paths_descendant_columns)
      end

      def self_and_descendants(node)
        reach(node, select_cols: config.paths_descendant_columns,
                    match_cols: config.paths_ancestor_columns)
      end

      def reachable?(ancestor, descendant)
        return false if same_node?(ancestor, descendant)

        key = config.paths_ancestor_columns.zip(node_values(ancestor))
                    .concat(config.paths_descendant_columns.zip(node_values(descendant)))
                    .to_h
        paths.exists?(key)
      end

      def apply_topological_order(relation)
        tp = paths.arel_table
        count = tp.project(Arel.star.count).where(
          config.paths_descendant_columns.zip(pk_columns)
                .map { |dc, pk| tp[dc].eq(model.arel_table[pk]) }.inject(:and)
        )
        ordered_by(relation, count)
      end

      private

      # Nodes whose pk tuple appears in the paths table on `select_cols`,
      # restricted by the node's identity on `match_cols`.
      def reach(node, select_cols:, match_cols:)
        sub = paths.where(match_cols.zip(node_values(node)).to_h)
                   .select(*select_cols)
        model.where(pk_tuple_in(sub.arel.ast))
      end

      def paths
        config.paths_class
      end
    end
  end
end
