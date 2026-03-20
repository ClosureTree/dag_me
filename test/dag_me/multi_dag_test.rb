# frozen_string_literal: true

require 'test_helper'

# Relay declares two named DAGs over the same nodes: :power (closure) and
# :comms (recursive CTE). Each network is fully independent.
class MultiDagTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Relay)
  end

  def test_named_constants_and_tables
    assert Relay.const_defined?(:PowerDagEdge)
    assert Relay.const_defined?(:PowerDagPath)
    assert Relay.const_defined?(:CommsDagEdge)
    refute Relay.const_defined?(:CommsDagPath), 'recursive_cte materializes nothing'

    assert_equal 'relay_power_dag_edges', Relay::PowerDagEdge.table_name
    assert_equal 'relay_power_dag_paths', Relay::PowerDagPath.table_name
    assert_equal 'relay_comms_dag_edges', Relay::CommsDagEdge.table_name
  end

  def test_adapters_per_network
    assert_dag_model Relay, dag: :power, maintain: :postgresql_closure
    assert_dag_model Relay, dag: :comms, maintain: :recursive_cte
    assert_instance_of DagMe::Adapters::PostgresqlClosure, Relay.dag(:power).adapter
    assert_instance_of DagMe::Adapters::RecursiveCte, Relay.dag(:comms).adapter
  end

  def test_networks_are_independent
    a, b, c = create_relays(3)
    a.add_child(b, dag: :power)
    b.add_child(c, dag: :comms)

    assert a.ancestor_of?(b, dag: :power)
    refute a.ancestor_of?(b, dag: :comms)
    refute b.ancestor_of?(c, dag: :power)
    assert b.ancestor_of?(c, dag: :comms)

    assert_equal %w[b], a.power_children.pluck(:name)
    assert_empty a.comms_children
    assert_equal %w[c], b.comms_children.pluck(:name)
    assert_equal %w[b], c.comms_parents.pluck(:name)
  end

  def test_cycles_are_rejected_per_network_not_across
    a, b = create_relays(2)
    a.add_child(b, dag: :power)

    # Opposite direction in the other network is fine - different graph.
    b.add_child(a, dag: :comms)

    assert_raises(DagMe::CycleError) { b.add_child(a, dag: :power) }
    assert_raises(DagMe::CycleError) { a.add_child(b, dag: :comms) }
  end

  def test_roots_leaves_and_topology_per_network
    a, b, c = create_relays(3)
    a.add_child(b, dag: :power)
    b.add_child(c, dag: :power)
    c.add_child(a, dag: :comms)

    assert_equal %w[a], Relay.roots(dag: :power).pluck(:name)
    assert_equal %w[c], Relay.leaves(dag: :power).pluck(:name)
    # b has no comms edges at all, so it is a comms root alongside c.
    assert_equal %w[b c], Relay.roots(dag: :comms).order(:name).pluck(:name)

    assert_equal %w[a b c], Relay.topologically(:power).pluck(:name)
    assert_topological_order Relay, Relay.topologically(:comms).to_a, dag: :comms

    assert a.root?(dag: :power)
    refute a.root?(dag: :comms)
    assert c.leaf?(dag: :power)
  end

  def test_walks_and_subgraphs_per_network
    a, b, c, d = create_relays(4)
    a.add_child(b, dag: :power)
    b.add_child(c, dag: :power)
    a.add_child(d, dag: :comms)

    assert_equal %w[b c], a.descendants(dag: :power).order(:name).pluck(:name)
    assert_equal %w[d], a.descendants(dag: :comms).pluck(:name)
    assert_equal %w[a b], c.ancestors(dag: :power).order(:name).pluck(:name)

    assert_equal %w[a b c], Relay.dag(:power).between(a, c).order(:name).pluck(:name)
    assert_equal %w[a b c], a.subgraph(dag: :power).order(:name).pluck(:name)
    assert_equal 2, a.subgraph_edges(dag: :power).count
    assert_equal 1, a.subgraph_edges(dag: :comms).count
  end

  def test_removal_and_rebuild_per_network
    a, b = create_relays(2)
    a.add_child(b, dag: :power)
    a.add_child(b, dag: :comms)

    a.remove_child(b, dag: :power)

    refute a.ancestor_of?(b, dag: :power)
    assert a.ancestor_of?(b, dag: :comms)

    Relay.dag(:power).rebuild!

    assert_empty Relay.dag(:power).validate
    assert_dag_valid Relay, dag: :power
  end

  def test_unknown_and_missing_default_dags_raise
    error = assert_raises(ArgumentError) { Relay.dag }

    assert_match(/unknown dag :default/, error.message)
    assert_match(/:power, :comms/, error.message)
    assert_raises(ArgumentError) { Relay.dag(:gravity) }
    assert_nil Relay.dag_config
  end

  def test_status_reports_each_network
    io = StringIO.new
    DagMe::TaskHelpers.status([Relay], io: io)
    report = io.string

    assert_includes report, 'Relay [power]'
    assert_includes report, 'Relay [comms]'
    assert_includes report, 'closure: not materialized (recursive_cte)'
  end

  private

  def create_relays(count)
    ('a'..).first(count).map { |n| Relay.create!(name: n) }
  end
end
