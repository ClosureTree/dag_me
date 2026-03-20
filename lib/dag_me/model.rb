# frozen_string_literal: true

module DagMe
  module Model
    extend ActiveSupport::Concern

    # Builds the per-dag machinery: edge/paths constants and associations.
    # Called by the macro once per dag_me declaration, so a model hosting
    # several named graphs gets one full set each.
    def self.attach(model, config)
      parent_fk = config.composite_pk? ? config.edge_parent_columns.map(&:to_sym) : :parent_id
      child_fk = config.composite_pk? ? config.edge_child_columns.map(&:to_sym) : :child_id
      pk_opt = config.composite_pk? ? { primary_key: config.node_pk_columns.map(&:to_sym) } : {}

      child_edges = config.association_name('dag_child_edges')
      parent_edges = config.association_name('dag_parent_edges')

      edge_class = Class.new(ActiveRecord::Base)
      model.const_set(config.edge_class_name, edge_class)
      edge_class.table_name = config.edge_table
      edge_class.belongs_to :parent, class_name: model.name, foreign_key: parent_fk,
                                     inverse_of: child_edges, **pk_opt
      edge_class.belongs_to :child, class_name: model.name, foreign_key: child_fk,
                                    inverse_of: parent_edges, **pk_opt

      if config.closure?
        paths_class = Class.new(ActiveRecord::Base)
        model.const_set(config.paths_class_name, paths_class)
        paths_class.table_name = config.paths_table
        paths_class.primary_key = config.paths_ancestor_columns + config.paths_descendant_columns
      end

      model.has_many child_edges, class_name: "#{model.name}::#{config.edge_class_name}",
                                  foreign_key: parent_fk, inverse_of: :parent, dependent: nil, **pk_opt
      model.has_many config.association_name('children'), through: child_edges, source: :child
      model.has_many parent_edges, class_name: "#{model.name}::#{config.edge_class_name}",
                                   foreign_key: child_fk, inverse_of: :child, dependent: nil, **pk_opt
      model.has_many config.association_name('parents'), through: parent_edges, source: :parent
    end

    included do
      # A valid topological order: nodes with fewer ancestors always come
      # before their descendants. Composes with any relation, e.g.
      # `node.descendants.topologically` or `Relay.topologically(:power)`.
      scope :topologically, ->(dag_name = nil) { dag(dag_name).adapter.apply_topological_order(all) }
    end

    class_methods do
      # Graph-wide operations: Task.dag.between(a, b), Task.dag.rebuild!,
      # Relay.dag(:power).valid?, Task.dag.edges_among(relation), ...
      def dag(name = nil)
        config = dag_config_for(name)
        @dags ||= {}
        @dags[name&.to_sym || :default] ||= DagMe::Graph.new(self, config)
      end

      # The default (unnamed) dag's configuration; nil when the model only
      # declares named dags.
      def dag_config
        dag_configs[:default]
      end

      def dag_config_for(name)
        key = name&.to_sym || :default
        dag_configs.fetch(key) do
          raise ArgumentError,
                "#{self.name}: unknown dag #{key.inspect} (defined: #{dag_configs.keys.map(&:inspect).join(', ')})"
        end
      end

      def roots(dag: nil)
        dag_nodes_without(dag_config_for(dag), :edge_child_columns)
      end

      def leaves(dag: nil)
        dag_nodes_without(dag_config_for(dag), :edge_parent_columns)
      end

      private

      # Nodes with no edge row in the given role (child -> roots, parent -> leaves).
      def dag_nodes_without(config, role)
        edge = Arel::Table.new(config.edge_table)
        conds = config.node_pk_columns.zip(config.public_send(role))
                      .map { |pk, edge_col| edge[edge_col].eq(arel_table[pk]) }.inject(:and)
        where.not(edge.project(1).where(conds).exists)
      end
    end

    def add_child(node, dag: nil)
      config = self.class.dag_config_for(dag)
      DagMe.translate_errors { config.edge_class.create!(parent: self, child: node) }
      node
    end

    def add_parent(node, dag: nil)
      config = self.class.dag_config_for(dag)
      DagMe.translate_errors { config.edge_class.create!(parent: node, child: self) }
      node
    end

    def remove_child(node, dag: nil)
      config = self.class.dag_config_for(dag)
      DagMe.translate_errors do
        config.edge_class.where(dag_edge_key(config, parent: self, child: node)).delete_all
      end
      node
    end

    def remove_parent(node, dag: nil)
      config = self.class.dag_config_for(dag)
      DagMe.translate_errors do
        config.edge_class.where(dag_edge_key(config, parent: node, child: self)).delete_all
      end
      node
    end

    def ancestors(dag: nil)
      self.class.dag(dag).adapter.ancestors(self)
    end

    def descendants(dag: nil)
      self.class.dag(dag).adapter.descendants(self)
    end

    def self_and_ancestors(dag: nil)
      self.class.dag(dag).adapter.self_and_ancestors(self)
    end

    def self_and_descendants(dag: nil)
      self.class.dag(dag).adapter.self_and_descendants(self)
    end

    def ancestor_of?(node, dag: nil)
      self.class.dag(dag).adapter.reachable?(self, node)
    end

    def descendant_of?(node, dag: nil)
      self.class.dag(dag).adapter.reachable?(node, self)
    end

    # The induced subgraph rooted here: this node, its descendants, and the
    # edges among them.
    def subgraph(dag: nil)
      self_and_descendants(dag:)
    end

    def subgraph_edges(dag: nil)
      self.class.dag(dag).edges_among(self_and_descendants(dag:))
    end

    def root?(dag: nil)
      config = self.class.dag_config_for(dag)
      !public_send(config.association_name('dag_parent_edges')).exists?
    end

    def leaf?(dag: nil)
      config = self.class.dag_config_for(dag)
      !public_send(config.association_name('dag_child_edges')).exists?
    end

    private

    # {parent_id: ..., child_id: ...} - one pair per pk column for composite keys.
    def dag_edge_key(config, parent:, child:)
      config.edge_parent_columns.zip(Array(parent.id))
            .concat(config.edge_child_columns.zip(Array(child.id)))
            .to_h
    end
  end
end
