# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/migration'
require 'rails/generators/active_record'

module DagMe
  module Generators
    # rails generate dag_me:migration Task
    class MigrationGenerator < Rails::Generators::NamedBase
      include Rails::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      def create_migration_file
        migration_template 'install_dag.rb.erb', "db/migrate/install_dag_me_for_#{file_name.pluralize}.rb"
      end

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
