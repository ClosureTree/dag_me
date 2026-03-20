# frozen_string_literal: true

require 'test_helper'

class TopologicalTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Mission)
    wipe!(Maneuver)
  end

  def test_whole_graph_topological_order
    build_dag(Mission, %w[a>b a>c b>d c>d d>e])
    ordered = Mission.topologically.to_a

    assert_equal 5, ordered.length
    assert_topological_order(Mission, ordered)
    assert_equal 'a', ordered.first.name
    assert_equal 'e', ordered.last.name
  end

  def test_composes_with_descendant_relations
    nodes = build_dag(Mission, %w[a>b a>c b>d c>d d>e z>a])
    ordered = nodes['a'].self_and_descendants.topologically.to_a

    assert_equal %w[a b c d e], ordered.map(&:name).sort
    assert_topological_order(Mission, ordered)
    assert_equal 'a', ordered.first.name
  end

  def test_deterministic_tie_break
    build_dag(Mission, %w[a>b a>c])

    assert_equal Mission.topologically.pluck(:id), Mission.topologically.pluck(:id)
  end

  def test_multiple_roots
    build_dag(Mission, %w[a>c b>c c>d])
    ordered = Mission.topologically.to_a

    assert_topological_order(Mission, ordered)
    assert_equal 'd', ordered.last.name
  end

  def test_cte_adapter_topological_order
    build_dag(Maneuver, %w[a>b a>c b>d c>d d>e])
    ordered = Maneuver.topologically.to_a

    assert_equal 5, ordered.length
    assert_topological_order(Maneuver, ordered)
    assert_equal 'a', ordered.first.name
    assert_equal 'e', ordered.last.name
  end
end
