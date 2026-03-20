# frozen_string_literal: true

require 'rails/railtie'

module DagMe
  class Railtie < Rails::Railtie # :nodoc:
    generators do
      require_relative '../generators/dag_me/migration_generator'
    end

    rake_tasks do
      load 'dag_me/railties/tasks.rake'
    end
  end
end
