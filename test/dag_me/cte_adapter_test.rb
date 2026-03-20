# frozen_string_literal: true

require 'test_helper'

class CteAdapterTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Maneuver)
  end

  def test_uses_recursive_cte_adapter
    assert_instance_of DagMe::Adapters::RecursiveCte, Maneuver.dag.adapter
  end

  def test_ancestors_and_descendants_through_diamond
    nodes = build_dag(Maneuver, %w[a>b a>c b>d c>d d>e])

    assert_equal %w[b c d e], nodes['a'].descendants.order(:name).pluck(:name)
    assert_equal %w[a b c d], nodes['e'].ancestors.order(:name).pluck(:name)
    assert_equal %w[a b c d e], nodes['a'].self_and_descendants.order(:name).pluck(:name)
  end

  def test_cycle_rejected_via_cte_trigger
    nodes = build_dag(Maneuver, %w[a>b b>c])

    assert_raises(DagMe::CycleError) { nodes['c'].add_child(nodes['a']) }
  end

  def test_reachability_predicates
    nodes = build_dag(Maneuver, %w[a>b b>c])

    assert nodes['a'].ancestor_of?(nodes['c'])
    refute nodes['c'].ancestor_of?(nodes['a'])
  end

  def test_roots_and_leaves
    build_dag(Maneuver, %w[a>b a>c b>d])

    assert_equal %w[a], Maneuver.roots.pluck(:name)
    assert_equal %w[c d], Maneuver.leaves.order(:name).pluck(:name)
  end

  def test_no_paths_constant
    refute Maneuver.const_defined?(:DagPath)
  end
end
