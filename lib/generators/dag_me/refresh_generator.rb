# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/migration'
require 'rails/generators/active_record'

module DagMe
  module Generators
    # rails generate dag_me:refresh Task
    #
    # Upgrades an installed graph's function bodies to the current
    # DagMe::DDL::REVISION. Named after the revision, so later refreshes
    # get their own migration.
    #
    # The migration pins each dag to its node table and options instead of
    # naming the model: migrations replay long after a model is renamed or
    # removed, and a missing constant would abort db:migrate.
    class RefreshGenerator < Rails::Generators::NamedBase
      include Rails::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      # Keyword arguments that rebuild +config+ on a stand-in model carrying
      # only its table name (and composite key). The prefix is always pinned;
      # table names only when they were overridden rather than derived.
      def self.snapshot(config)
        options = { primary_key: (config.node_pk_columns.map(&:to_sym) if config.composite_pk?),
                    name: config.name,
                    maintain: config.maintain,
                    scope: config.scope_columns.presence,
                    prefix: config.prefix }
        options[:edge_table] = config.edge_table unless config.edge_table == config.qualify("#{config.prefix}_edges")
        options[:paths_table] = config.paths_table unless config.paths_table == config.qualify("#{config.prefix}_paths")
        options.compact
      end

      def check_dag_model
        return if model.is_a?(Class) && model.include?(DagMe::Model)

        raise Thor::Error, "#{class_name} is not a dag_me model (no dag_me call)"
      end

      def create_migration_file
        migration_template 'refresh_dag.rb.erb', "db/migrate/refresh_dag_me_r#{revision}_for_#{table_name}.rb"
      end

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      private

      def model
        @model ||= class_name.safe_constantize
      end

      def refresh_calls
        model.dag_configs.each_value.map do |config|
          args = self.class.snapshot(config).map { |key, value| "#{key}: #{value.inspect}" }
          "refresh #{[config.node_table.inspect, *args].join(', ')}"
        end
      end

      def revision
        DagMe::DDL::REVISION
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
