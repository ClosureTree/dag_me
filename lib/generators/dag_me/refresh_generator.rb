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
    class RefreshGenerator < Rails::Generators::NamedBase
      include Rails::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      def create_migration_file
        migration_template 'refresh_dag.rb.erb',
                           "db/migrate/refresh_dag_me_r#{revision}_for_#{file_name.pluralize}.rb"
      end

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      private

      def revision
        DagMe::DDL::REVISION
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
