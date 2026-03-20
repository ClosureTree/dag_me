# frozen_string_literal: true

require 'test_helper'

class UuidTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Probe)
  end

  def test_uuid_diamond
    nodes = build_dag(Probe, %w[a>b a>c b>d c>d])

    assert_equal %w[b c d], nodes['a'].descendants.order(:name).pluck(:name)
    row = Probe::DagPath.find_by!(ancestor_id: nodes['a'].id, descendant_id: nodes['d'].id)

    assert_equal 2, row.path_count.to_i
    assert_empty Probe.dag.validate
  end

  def test_uuid_pk_type_propagates_to_graph_tables
    assert_equal 'uuid', Probe.connection.columns('probe_dag_edges').find { |c| c.name == 'parent_id' }.sql_type
    assert_equal 'uuid', Probe.connection.columns('probe_dag_paths').find { |c| c.name == 'ancestor_id' }.sql_type
  end

  def test_uuid_cycle_rejected
    nodes = build_dag(Probe, %w[a>b b>c])

    assert_raises(DagMe::CycleError) { nodes['c'].add_child(nodes['a']) }
  end

  def test_uuid_deletion_maintenance
    nodes = build_dag(Probe, %w[a>b a>c b>d c>d])
    nodes['b'].remove_child(nodes['d'])

    assert nodes['a'].ancestor_of?(nodes['d'])
    assert_equal 1, Probe::DagPath.find_by!(ancestor_id: nodes['a'].id, descendant_id: nodes['d'].id).path_count.to_i
    assert_empty Probe.dag.validate
  end

  def test_uuid_node_destruction
    nodes = build_dag(Probe, %w[a>b b>c])
    nodes['b'].destroy!

    refute nodes['a'].ancestor_of?(nodes['c'])
    assert_empty Probe.dag.validate
  end

  def test_uuid_topological_and_between
    nodes = build_dag(Probe, %w[a>b a>c b>d c>d])
    ordered = Probe.dag.between(nodes['a'], nodes['d']).topologically.to_a

    assert_equal 4, ordered.length
    assert_topological_order(Probe, ordered)
    assert_equal 'a', ordered.first.name
    assert_equal 'd', ordered.last.name
  end

  def test_uuid_rebuild
    build_dag(Probe, %w[a>b a>c b>d])
    Probe.dag.rebuild!

    assert_empty Probe.dag.validate
  end
end
