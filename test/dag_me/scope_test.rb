# frozen_string_literal: true

require 'test_helper'

class ScopeTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Satellite)
    wipe!(Outpost)
  end

  def test_same_scope_edges_allowed
    nodes = build_dag(Satellite, %w[a>b b>c], constellation_id: 1)

    assert_equal %w[b c], nodes['a'].descendants.order(:name).pluck(:name)
    assert_empty Satellite.dag.validate
  end

  def test_cross_scope_edge_rejected
    a = Satellite.create!(name: 'a', constellation_id: 1)
    b = Satellite.create!(name: 'b', constellation_id: 2)

    assert_raises(DagMe::ScopeError) { a.add_child(b) }
  end

  def test_cross_scope_rejected_for_raw_sql_writers
    a = Satellite.create!(name: 'a', constellation_id: 1)
    b = Satellite.create!(name: 'b', constellation_id: 2)

    error = assert_raises(ActiveRecord::StatementInvalid) do
      Satellite.connection.execute(
        "INSERT INTO satellite_dag_edges (parent_id, child_id) VALUES (#{a.id}, #{b.id})"
      )
    end
    assert_match(/crosses scope/, error.message)
  end

  def test_scope_stamped_on_edges_and_paths
    build_dag(Satellite, %w[a>b], constellation_id: 7)

    assert_equal [7], Satellite::DagEdge.distinct.pluck(:constellation_id)
    assert_equal [7], Satellite::DagPath.distinct.pluck(:constellation_id)
  end

  def test_scope_stamp_cannot_be_forged_by_raw_sql
    a = Satellite.create!(name: 'a', constellation_id: 3)
    b = Satellite.create!(name: 'b', constellation_id: 3)
    Satellite.connection.execute(
      "INSERT INTO satellite_dag_edges (parent_id, child_id, constellation_id) VALUES (#{a.id}, #{b.id}, 999)"
    )

    assert_equal [3], Satellite::DagEdge.distinct.pluck(:constellation_id)
    assert_empty Satellite.dag.validate
  end

  def test_tenants_are_isolated_graphs
    one = build_dag(Satellite, %w[a>b b>c], constellation_id: 1)
    two = build_dag(Satellite, %w[x>y], constellation_id: 2)

    assert_equal %w[b c], one['a'].descendants.order(:name).pluck(:name)
    assert_equal %w[y], two['x'].descendants.pluck(:name)
    assert_equal %w[a x], Satellite.roots.order(:name).pluck(:name)
    assert_equal %w[a], Satellite.roots.where(constellation_id: 1).pluck(:name)
  end

  def test_scope_change_rejected_while_connected
    nodes = build_dag(Satellite, %w[a>b], constellation_id: 1)

    error = assert_raises(ActiveRecord::StatementInvalid) { nodes['a'].update!(constellation_id: 2) }

    assert_match(/cannot change scope/, error.message)
  end

  def test_scope_change_allowed_when_isolated_and_restamps_self_row
    node = Satellite.create!(name: 'a', constellation_id: 1)
    node.update!(constellation_id: 2)

    self_row = Satellite::DagPath.find_by!(ancestor_id: node.id, descendant_id: node.id)

    assert_equal 2, self_row.constellation_id
    assert_empty Satellite.dag.validate
  end

  def test_scope_change_allowed_after_disconnecting
    nodes = build_dag(Satellite, %w[a>b], constellation_id: 1)
    nodes['a'].remove_child(nodes['b'])
    nodes['b'].update!(constellation_id: 2)

    assert_empty Satellite.dag.validate
  end

  def test_rebuild_preserves_scope
    build_dag(Satellite, %w[a>b b>c], constellation_id: 5)
    Satellite.dag.rebuild!

    assert_equal [5], Satellite::DagPath.distinct.pluck(:constellation_id)
    assert_empty Satellite.dag.validate
  end

  def test_deletion_maintenance_within_scope
    nodes = build_dag(Satellite, %w[a>b a>c b>d c>d], constellation_id: 1)
    build_dag(Satellite, %w[p>q], constellation_id: 2)

    nodes['b'].remove_child(nodes['d'])

    assert nodes['a'].ancestor_of?(nodes['d'])
    assert_empty Satellite.dag.validate
  end

  def test_multi_column_scope_edges_allowed_only_with_identical_scope_tuple
    a = Outpost.create!(name: 'a', system_id: 1, sector: 'us')
    b = Outpost.create!(name: 'b', system_id: 1, sector: 'us')
    different_region = Outpost.create!(name: 'c', system_id: 1, sector: 'eu')
    different_account = Outpost.create!(name: 'd', system_id: 2, sector: 'us')

    a.add_child(b)

    assert_equal ['b'], a.descendants.pluck(:name)
    assert_raises(DagMe::ScopeError) { a.add_child(different_region) }
    assert_raises(DagMe::ScopeError) { a.add_child(different_account) }
    assert_empty Outpost.dag.validate
  end

  def test_multi_column_scope_is_stamped_and_cannot_be_forged_by_raw_sql
    a = Outpost.create!(name: 'a', system_id: 3, sector: 'us')
    b = Outpost.create!(name: 'b', system_id: 3, sector: 'us')

    Outpost.connection.execute(<<~SQL)
      INSERT INTO outpost_dag_edges (parent_id, child_id, system_id, sector)
      VALUES (#{a.id}, #{b.id}, 999, 'forged')
    SQL

    edge_scopes = Outpost::DagEdge.distinct.pluck(:system_id, :sector)
    path_scopes = Outpost::DagPath.where('ancestor_id <> descendant_id').distinct.pluck(:system_id, :sector)

    assert_equal [[3, 'us']], edge_scopes
    assert_equal [[3, 'us']], path_scopes
    assert_empty Outpost.dag.validate
  end

  def test_multi_column_scope_change_restamps_isolated_self_row
    node = Outpost.create!(name: 'a', system_id: 1, sector: 'us')

    node.update!(system_id: 2, sector: 'eu')

    self_row = Outpost::DagPath.find_by!(ancestor_id: node.id, descendant_id: node.id)

    assert_equal [2, 'eu'], [self_row.system_id, self_row.sector]
    assert_empty Outpost.dag.validate
  end

  # Scope change racing an uncommitted edge insert blocks on FOR SHARE,
  # then sees the committed edge and gets rejected.
  def test_scope_change_loses_race_against_in_flight_edge_insert
    a = Satellite.create!(name: 'a', constellation_id: 1)
    b = Satellite.create!(name: 'b', constellation_id: 1)
    edge_open = Queue.new
    release = Queue.new

    inserter = Thread.new do
      Satellite.connection_pool.with_connection do
        Satellite.transaction do
          a.add_child(b)
          edge_open << true
          release.pop
        end
      end
    end

    edge_open.pop
    updater = Thread.new do
      Satellite.connection_pool.with_connection do
        assert_raises(ActiveRecord::StatementInvalid) { b.update!(constellation_id: 2) }
      end
    end

    sleep 0.2 # let the updater reach the row-lock wait before the edge commits
    release << true
    [inserter, updater].each(&:join)

    assert_equal [1], Satellite::DagEdge.distinct.pluck(:constellation_id)
    assert_equal 1, b.reload.constellation_id
    assert_empty Satellite.dag.validate
  end

  # Reverse order: the edge insert blocks, re-reads the new scope, rejected.
  def test_edge_insert_loses_race_against_in_flight_scope_change
    a = Satellite.create!(name: 'a', constellation_id: 1)
    b = Satellite.create!(name: 'b', constellation_id: 1)
    update_open = Queue.new
    release = Queue.new

    updater = Thread.new do
      Satellite.connection_pool.with_connection do
        Satellite.transaction do
          b.update!(constellation_id: 2)
          update_open << true
          release.pop
        end
      end
    end

    update_open.pop
    inserter = Thread.new do
      Satellite.connection_pool.with_connection do
        assert_raises(DagMe::ScopeError) { a.add_child(b) }
      end
    end

    sleep 0.2 # let the inserter reach the FOR SHARE wait before the update commits
    release << true
    [updater, inserter].each(&:join)

    assert_empty Satellite::DagEdge.where(parent_id: a.id, child_id: b.id)
    assert_empty Satellite.dag.validate
  end

  def test_multi_column_scope_change_rejected_while_connected
    nodes = build_dag(Outpost, %w[a>b], system_id: 1, sector: 'us')

    error = assert_raises(ActiveRecord::StatementInvalid) do
      nodes['a'].update!(sector: 'eu')
    end

    assert_match(/cannot change scope/, error.message)
  end
end
