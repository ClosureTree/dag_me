# frozen_string_literal: true

module DagMe
  module Macro
    # Declares a DAG on the model. Called bare it defines the model's default
    # graph; called with a name it defines an independent named graph, so one
    # node can belong to many networks:
    #
    #   class Relay < ApplicationRecord
    #     dag_me :power
    #     dag_me :comms, maintain: :recursive_cte
    #   end
    #
    #   relay.add_child(other, dag: :power)
    #   relay.comms_children
    #   Relay.dag(:power).rebuild!
    def dag_me(name = nil, maintain: :postgresql_closure, scope: nil, prefix: nil, edge_table: nil, paths_table: nil)
      key = name&.to_sym || :default
      unless include?(DagMe::Model)
        class_attribute :dag_configs, instance_writer: false, instance_predicate: false, default: {}.freeze
        include DagMe::Model
      end
      raise ArgumentError, "#{self.name}: dag #{key.inspect} is already defined" if dag_configs.key?(key)

      config = Configuration.new(model: self, name: name&.to_sym, maintain:, scope:, prefix:, edge_table:, paths_table:)
      self.dag_configs = dag_configs.merge(key => config).freeze
      DagMe::Model.attach(self, config)
      self
    end
  end
end
