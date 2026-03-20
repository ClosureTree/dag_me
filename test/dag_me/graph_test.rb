# frozen_string_literal: true

require 'test_helper'

class GraphTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Mission)
  end

  def test_valid_predicate
    build_dag(Mission, %w[a>b b>c])

    assert_predicate Mission.dag, :valid?
    assert Mission.dag.validate!
  end

  def test_validate_bang_raises_with_discrepancies_on_corruption
    build_dag(Mission, %w[a>b])
    # The paths table has no triggers of its own, so this corrupts the closure.
    Mission::DagPath.where('ancestor_id <> descendant_id').delete_all

    error = assert_raises(DagMe::CorruptionError) { Mission.dag.validate! }

    assert_equal 1, error.discrepancies.length
    Mission.dag.rebuild!

    assert_predicate Mission.dag, :valid?
  end

  def test_edges_relation
    build_dag(Mission, %w[a>b a>c])

    assert_equal 2, Mission.dag.edges.count
    assert_kind_of ActiveRecord::Relation, Mission.dag.edges
  end

  def test_cte_graph_is_always_valid_and_rebuild_is_noop
    assert_predicate Maneuver.dag, :valid?
    assert Maneuver.dag.rebuild!
  end
end
