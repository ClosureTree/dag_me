# frozen_string_literal: true

module DagMe
  # Minitest assertions for host applications:
  #
  #   class GraphSetupTest < ActiveSupport::TestCase
  #     include DagMe::TestHelper
  #
  #     test 'tasks form a healthy DAG' do
  #       assert_dag_model Task, maintain: :postgresql_closure
  #       assert_dag_valid Task
  #     end
  #   end
  module TestHelper
    # Asserts the class is wired up as a dag_me model, optionally pinning
    # the maintain mode and scope columns. Pass dag: for a named graph.
    def assert_dag_model(klass, maintain: nil, scope: nil, dag: nil)
      assert klass.include?(DagMe::Model), "#{klass} should call dag_me"

      config = klass.dag_config_for(dag)
      if maintain
        assert_equal maintain, config.maintain,
                     "#{klass} should maintain its DAG via #{maintain}"
      end

      return unless scope

      assert_equal Array(scope).map(&:to_sym), config.scope_columns,
                   "#{klass} should be scoped by #{Array(scope).join(', ')}"
    end

    # Asserts the stored closure agrees with the recursive-CTE truth.
    def assert_dag_valid(klass, dag: nil)
      discrepancies = klass.dag(dag).validate

      assert_empty discrepancies,
                   "#{klass} closure diverged from edge truth: #{discrepancies.inspect}"
    end

    def assert_dag_reachable(ancestor, descendant, dag: nil)
      assert ancestor.ancestor_of?(descendant, dag:),
             "expected #{node_label(ancestor)} to reach #{node_label(descendant)}"
    end

    def refute_dag_reachable(ancestor, descendant, dag: nil)
      refute ancestor.ancestor_of?(descendant, dag:),
             "expected #{node_label(ancestor)} not to reach #{node_label(descendant)}"
    end

    # Asserts the ordered node list is a valid topological order: for every
    # edge among the listed nodes, the parent appears before the child.
    def assert_topological_order(model, ordered_nodes, dag: nil)
      config = model.dag_config_for(dag)
      position = ordered_nodes.each_with_index.to_h { |node, i| [Array(node.id), i] }

      model.dag(dag).edges.find_each do |edge|
        parent_key = config.edge_parent_columns.map { |c| edge[c] }
        child_key = config.edge_child_columns.map { |c| edge[c] }
        next unless position.key?(parent_key) && position.key?(child_key)

        assert_operator position[parent_key], :<, position[child_key],
                        "edge #{parent_key.join('/')} -> #{child_key.join('/')} violates topological order"
      end
    end

    private

    def node_label(node)
      "#{node.class.name}##{node.id}"
    end
  end
end
