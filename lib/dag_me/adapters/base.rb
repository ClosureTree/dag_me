# frozen_string_literal: true

module DagMe
  module Adapters
    # The reachability interface. The model layer only talks to this; whether
    # answers come from the materialized closure or a recursive CTE is an
    # adapter concern.
    class Base
      attr_reader :config

      def initialize(config)
        @config = config
      end

      def model
        config.model
      end

      def ancestors(node)
        raise NotImplementedError
      end

      def descendants(node)
        raise NotImplementedError
      end

      def self_and_ancestors(node)
        raise NotImplementedError
      end

      def self_and_descendants(node)
        raise NotImplementedError
      end

      # True when `ancestor` reaches `descendant` through one or more edges.
      def reachable?(ancestor, descendant)
        raise NotImplementedError
      end

      # Nodes on any path from `ancestor` to `descendant`, endpoints included:
      # self_and_descendants(ancestor) ∩ self_and_ancestors(descendant).
      def between(ancestor, descendant)
        self_and_descendants(ancestor).and(self_and_ancestors(descendant))
      end

      # Orders a relation so ancestors always precede descendants. Both
      # adapters sort by global ancestor count: for any edge u -> v,
      # ancestors(v) ⊇ ancestors(u) ∪ {u}, so the count strictly increases
      # along every edge - a valid topological order for any sub-relation.
      def apply_topological_order(relation)
        raise NotImplementedError
      end

      private

      def pk_columns
        config.node_pk_columns
      end

      # Node identity values in pk-column order (composite ids are arrays).
      def node_values(node)
        Array(node.id)
      end

      def node_key(node)
        pk_columns.zip(node_values(node)).to_h
      end

      def same_node?(one, other)
        node_values(one) == node_values(other)
      end

      # ("tasks"."id") / ("widgets"."org_id", "widgets"."serial") - the node's
      # pk as a row value, for tuple membership tests against a subquery.
      def pk_tuple_in(subquery_ast)
        tuple = Arel::Nodes::Grouping.new(pk_columns.map { |c| model.arel_table[c] })
        Arel::Nodes::In.new(tuple, subquery_ast)
      end

      def ordered_by(relation, count_subquery)
        relation.order(Arel::Nodes::Ascending.new(Arel::Nodes::Grouping.new(count_subquery.ast)))
                .order(**pk_order)
      end

      def pk_order
        pk_columns.to_h { |c| [c.to_sym, :asc] }
      end
    end
  end
end
