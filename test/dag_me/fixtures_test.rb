# frozen_string_literal: true

require 'test_helper'

# Loads the vial-generated layered graph (120 nodes, 300 edges, 6 layers,
# 3 parents per node) through Rails fixtures. Fixture loading bypasses
# triggers (disable_referential_integrity), which makes this the documented
# bulk-import path: load edges raw, then rebuild the closure.
class FixturesTest < Minitest::Test
  include DagTestHelpers

  LAYERS = 6
  WIDTH = 20

  def setup
    wipe!(Mission)
    DagMeFixtures.load!('missions', 'mission_dag_edges',
                        'missions' => Mission, 'mission_dag_edges' => Mission::DagEdge)
    Mission.dag.rebuild!
    bump_sequences
  end

  def test_bulk_loaded_graph_is_exact
    assert_equal LAYERS * WIDTH, Mission.count
    assert_equal (LAYERS - 1) * WIDTH * 3, Mission.dag.edges.count
    assert_dag_valid Mission
  end

  def test_layer_structure
    assert_equal (1..WIDTH).to_a, Mission.roots.order(:id).pluck(:id)
    assert_equal ((((LAYERS - 1) * WIDTH) + 1)..(LAYERS * WIDTH)).to_a, Mission.leaves.order(:id).pluck(:id)
  end

  def test_min_depth_equals_layer_distance
    # Offset 0 gives every position a straight chain down: 1 -> 21 -> ... -> 101.
    row = Mission::DagPath.find_by!(ancestor_id: 1, descendant_id: 101)

    assert_equal LAYERS - 1, row.min_depth
    assert_operator row.path_count.to_i, :>, 1, 'expected combinatorial path fan-out'
  end

  def test_topological_order_over_large_graph
    ordered = Mission.topologically.to_a

    assert_equal LAYERS * WIDTH, ordered.length
    assert_topological_order Mission, ordered
    assert_equal (1..WIDTH).to_a, ordered.first(WIDTH).map(&:id).sort
  end

  def test_incremental_maintenance_continues_after_bulk_load
    extra = Mission.create!(name: 'extra')
    Mission.find(101).add_child(extra)

    assert_dag_reachable Mission.find(1), extra
    assert_raises(DagMe::CycleError) { extra.add_child(Mission.find(1)) }

    Mission.find(101).remove_child(extra)

    refute_dag_reachable Mission.find(1), extra
    assert_dag_valid Mission
  end

  private

  # Fixtures insert explicit ids without touching the identity sequences.
  def bump_sequences
    %w[missions mission_dag_edges].each do |table|
      Mission.connection.execute(
        "SELECT setval(pg_get_serial_sequence('#{table}', 'id'), (SELECT MAX(id) FROM #{table}))"
      )
    end
  end
end
