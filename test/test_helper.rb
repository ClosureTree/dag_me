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

  # The closure by brute force: enumerate every path with UNION ALL and
  # count. Exponential in the number of diamonds, so small graphs only, but
  # independent of both the triggers and the layered recomputation.
  # Single-column keys. Rows are [ancestor, descendant, min_depth, path_count].
  def brute_force_closure(model)
    edges = model.dag.config.edge_table
    model.connection.select_rows(<<~SQL).map { |row| row.map(&:to_i) }.sort
      WITH RECURSIVE walk(ancestor_id, descendant_id, depth) AS (
        SELECT parent_id, child_id, 1 FROM #{edges}
        UNION ALL
        SELECT w.ancestor_id, e.child_id, w.depth + 1
        FROM walk w JOIN #{edges} e ON e.parent_id = w.descendant_id
      )
      SELECT ancestor_id, descendant_id, MIN(depth), COUNT(*) FROM walk GROUP BY ancestor_id, descendant_id
      UNION ALL
      SELECT id, id, 0, 1 FROM #{model.table_name}
    SQL
  end

  def stored_closure(model)
    model.dag.config.paths_class
         .pluck(:ancestor_id, :descendant_id, :min_depth, :path_count)
         .map { |row| row.map(&:to_i) }.sort
  end

  # Every closure row as a sorted list of attribute hashes - works for any
  # key shape and carries scope columns.
  def closure_rows(model)
    model.dag.config.paths_class.all.map(&:attributes).sort_by(&:inspect)
  end

  # `count` diamonds in a row (a -> b, a -> c, b -> d, c -> d, d is the
  # next a). Returns [first, last]; 2**count paths connect them.
  def diamond_chain(model, count)
    first = joint = model.create!(name: 'j0')
    count.times do |i|
      left = model.create!(name: "l#{i}")
      right = model.create!(name: "r#{i}")
      nxt = model.create!(name: "j#{i + 1}")
      joint.add_child(left)
      joint.add_child(right)
      left.add_child(nxt)
      right.add_child(nxt)
      joint = nxt
    end
    [first, joint]
  end
end
