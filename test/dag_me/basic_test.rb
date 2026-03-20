# frozen_string_literal: true

require 'test_helper'

class BasicTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Mission)
  end

  def test_add_child_and_parents
    nodes = build_dag(Mission, %w[a>b a>c b>d c>d])

    assert_equal %w[b c], nodes['a'].children.order(:name).pluck(:name)
    assert_equal %w[b c], nodes['d'].parents.order(:name).pluck(:name)
    assert_equal %w[a], nodes['b'].parents.pluck(:name)
  end

  def test_ancestors_and_descendants_through_diamond
    nodes = build_dag(Mission, %w[a>b a>c b>d c>d d>e])

    assert_equal %w[b c d e], nodes['a'].descendants.order(:name).pluck(:name)
    assert_equal %w[a b c d], nodes['e'].ancestors.order(:name).pluck(:name)
    assert_equal %w[a b c d e], nodes['a'].self_and_descendants.order(:name).pluck(:name)
  end

  def test_diamond_path_count_and_min_depth
    nodes = build_dag(Mission, %w[a>b a>c b>d c>d])
    row = Mission::DagPath.find_by!(ancestor_id: nodes['a'].id, descendant_id: nodes['d'].id)

    assert_equal 2, row.path_count.to_i
    assert_equal 2, row.min_depth
  end

  def test_cycle_rejected
    nodes = build_dag(Mission, %w[a>b b>c])

    assert_raises(DagMe::CycleError) { nodes['c'].add_child(nodes['a']) }
    assert_raises(DagMe::CycleError) { nodes['a'].add_parent(nodes['c']) }
  end

  def test_self_loop_rejected_as_cycle
    a = Mission.create!(name: 'a')

    assert_raises(DagMe::CycleError) { a.add_child(a) }
  end

  def test_cycle_rejected_for_raw_sql_writers
    nodes = build_dag(Mission, %w[a>b b>c])

    error = assert_raises(ActiveRecord::StatementInvalid) do
      Mission.connection.execute(
        "INSERT INTO mission_dag_edges (parent_id, child_id) VALUES (#{nodes['c'].id}, #{nodes['a'].id})"
      )
    end
    assert_match(/cycle/, error.message)
  end

  def test_raw_sql_writes_maintain_closure
    nodes = build_dag(Mission, %w[a>b])
    c = Mission.create!(name: 'c')
    Mission.connection.execute(
      "INSERT INTO mission_dag_edges (parent_id, child_id) VALUES (#{nodes['b'].id}, #{c.id})"
    )

    assert_equal %w[a b], c.ancestors.order(:name).pluck(:name)
    assert_empty Mission.dag.validate
  end

  def test_roots_and_leaves
    build_dag(Mission, %w[a>b a>c b>d c>d])
    lone = Mission.create!(name: 'z')

    assert_equal %w[a z], Mission.roots.order(:name).pluck(:name)
    assert_equal %w[d z], Mission.leaves.order(:name).pluck(:name)
    assert_predicate lone, :root?
    assert_predicate lone, :leaf?
  end

  def test_reachability_predicates
    nodes = build_dag(Mission, %w[a>b b>c])

    assert nodes['a'].ancestor_of?(nodes['c'])
    assert nodes['c'].descendant_of?(nodes['a'])
    refute nodes['c'].ancestor_of?(nodes['a'])
    refute nodes['a'].ancestor_of?(nodes['a'])
  end

  def test_remove_edge_keeps_alternate_path
    nodes = build_dag(Mission, %w[a>b a>c b>d c>d])
    nodes['b'].remove_child(nodes['d'])

    assert nodes['a'].ancestor_of?(nodes['d'])
    row = Mission::DagPath.find_by!(ancestor_id: nodes['a'].id, descendant_id: nodes['d'].id)

    assert_equal 1, row.path_count.to_i
    assert_empty Mission.dag.validate
  end

  def test_remove_edge_disconnects_when_no_alternate_path
    nodes = build_dag(Mission, %w[a>b b>c])
    nodes['a'].remove_child(nodes['b'])

    refute nodes['a'].ancestor_of?(nodes['b'])
    refute nodes['a'].ancestor_of?(nodes['c'])
    assert nodes['b'].ancestor_of?(nodes['c'])
    assert_empty Mission.dag.validate
  end

  def test_remove_shortcut_edge_repairs_min_depth
    nodes = build_dag(Mission, %w[a>b b>c a>c])
    row = Mission::DagPath.find_by!(ancestor_id: nodes['a'].id, descendant_id: nodes['c'].id)

    assert_equal 1, row.min_depth

    nodes['a'].remove_child(nodes['c'])

    assert_equal 2, row.reload.min_depth
    assert_empty Mission.dag.validate
  end

  def test_node_deletion_cleans_graph
    nodes = build_dag(Mission, %w[a>b b>c a>d])
    nodes['b'].destroy!

    refute nodes['a'].ancestor_of?(nodes['c'])
    assert nodes['a'].ancestor_of?(nodes['d'])
    assert_empty Mission.dag.validate
  end

  def test_duplicate_edge_rejected
    nodes = build_dag(Mission, %w[a>b])

    assert_raises(ActiveRecord::RecordNotUnique) { nodes['a'].add_child(nodes['b']) }
  end

  def test_rebuild_matches_incremental_maintenance
    build_dag(Mission, %w[a>b a>c b>d c>d d>e])
    before = Mission::DagPath.order(:ancestor_id, :descendant_id).map(&:attributes)
    Mission.dag.rebuild!
    after = Mission::DagPath.order(:ancestor_id, :descendant_id).map(&:attributes)

    assert_equal before, after
    assert_empty Mission.dag.validate
  end
end
