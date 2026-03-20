# frozen_string_literal: true

require 'test_helper'

class SubgraphTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Mission)
    wipe!(Maneuver)
  end

  def test_between_returns_nodes_on_paths
    nodes = build_dag(Mission, %w[a>b a>c b>d c>d d>e a>x y>d])

    between = Mission.dag.between(nodes['a'], nodes['d'])

    assert_equal %w[a b c d], between.order(:name).pluck(:name)
  end

  def test_between_excludes_unrelated_branches
    nodes = build_dag(Mission, %w[a>b b>c a>z c>w])

    assert_equal %w[a b c], Mission.dag.between(nodes['a'], nodes['c']).order(:name).pluck(:name)
  end

  def test_between_unreachable_pair_is_empty
    nodes = build_dag(Mission, %w[a>b c>d])

    assert_empty Mission.dag.between(nodes['a'], nodes['d']).to_a
  end

  def test_subgraph_and_edges
    nodes = build_dag(Mission, %w[a>b a>c b>d c>d z>a z>q])

    assert_equal %w[a b c d], nodes['a'].subgraph.order(:name).pluck(:name)

    edge_pairs = nodes['a'].subgraph_edges.map { |e| [e.parent_id, e.child_id] }
    expected = [%w[a b], %w[a c], %w[b d], %w[c d]].map { |p, c| [nodes[p].id, nodes[c].id] }

    assert_equal expected.sort, edge_pairs.sort
  end

  def test_between_composes_with_topological_order
    nodes = build_dag(Mission, %w[a>b a>c b>d c>d])
    ordered = Mission.dag.between(nodes['a'], nodes['d']).topologically.to_a

    assert_topological_order(Mission, ordered)
    assert_equal 'a', ordered.first.name
    assert_equal 'd', ordered.last.name
  end

  def test_cte_adapter_between_and_subgraph
    nodes = build_dag(Maneuver, %w[a>b a>c b>d c>d d>e a>x])

    assert_equal %w[a b c d], Maneuver.dag.between(nodes['a'], nodes['d']).order(:name).pluck(:name)
    assert_equal %w[a b c d e x], nodes['a'].subgraph.order(:name).pluck(:name)
    assert_equal 6, nodes['a'].subgraph_edges.count
  end
end
