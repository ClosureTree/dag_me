# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'

require 'minitest/autorun'
require 'minitest/reporters'
require_relative 'dummy/config/environment'

Minitest::Reporters.use! Minitest::Reporters::DefaultReporter.new(color: true)

module DagMeTestSchema
  module_function

  # Rebuilds the test database from the dummy app's migrations
  # (test/dummy/db/migrate), exactly as a host app would run them.
  def reset!
    ActiveRecord::Base.connection.execute('DROP SCHEMA public CASCADE; CREATE SCHEMA public;')
    ActiveRecord::Base.connection.execute('DROP SCHEMA IF EXISTS orbital CASCADE;')
    ActiveRecord::MigrationContext.new(Rails.application.paths['db/migrate'].expanded).migrate
  end
end

DagMeTestSchema.reset!

# Compile vial definitions (test/vials) into generated fixtures
# (test/fixtures, gitignored). Deterministic: same seed, same output.
module DagMeFixtures
  module_function

  def compile!
    require 'vial'
    Vial.configure do |config|
      config.source_paths = [File.expand_path('vials', __dir__)]
      config.output_path = File.expand_path('fixtures', __dir__)
      config.seed = 1
    end
    Vial.compile!
  end

  def load!(*names, class_map)
    ActiveRecord::FixtureSet.reset_cache
    ActiveRecord::FixtureSet.create_fixtures(
      File.expand_path('fixtures', __dir__), names, class_map
    )
  end
end

DagMeFixtures.compile!

module DagTestHelpers
  include DagMe::TestHelper

  # Builds nodes by name and edges from a compact spec:
  #   build_dag(Mission, %w[a>b a>c b>d c>d])
  # Returns a hash of name => node. Extra attributes apply to every node.
  def build_dag(model, edge_specs, attrs = {})
    nodes = Hash.new { |h, k| h[k] = model.create!(name: k, **attrs) }
    edge_specs.each do |spec|
      parent, child = spec.split('>')
      nodes[parent].add_child(nodes[child])
    end
    nodes
  end

  def wipe!(model)
    model.delete_all
  end
end
