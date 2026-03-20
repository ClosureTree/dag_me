# frozen_string_literal: true

require 'test_helper'

# Composite keys: per-column graph columns, full-tuple comparisons. The
# shared-component tests catch single-column matching bugs.
class CompositePkTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(PowerCell)
    wipe!(Antenna)
  end

  def make(model, org, slot, name)
    model.create!(ship_id: org, slot: slot, name: name)
  end

  def test_edges_reachability_and_closure_health
    a = make(PowerCell, 1, 1, 'a')
    b = make(PowerCell, 1, 2, 'b')
    c = make(PowerCell, 1, 3, 'c')
    a.add_child(b)
    b.add_child(c)

    assert_equal %w[b c], a.descendants.order(:name).pluck(:name)
    assert_equal %w[a b], c.ancestors.order(:name).pluck(:name)
    assert_equal %w[a b c], a.self_and_descendants.order(:name).pluck(:name)
    assert a.ancestor_of?(c)
    refute c.ancestor_of?(a)
    assert_equal %w[b], a.children.pluck(:name)
    assert_equal %w[b], c.parents.pluck(:name)
    assert_empty PowerCell.dag.validate
  end

  def test_cycle_rejected
    a = make(PowerCell, 1, 1, 'a')
    b = make(PowerCell, 1, 2, 'b')
    c = make(PowerCell, 1, 3, 'c')
    a.add_child(b)
    b.add_child(c)

    assert_raises(DagMe::CycleError) { c.add_child(a) }
    assert_raises(DagMe::CycleError) { a.add_parent(c) }
  end

  def test_shared_key_components_do_not_leak_across_tuples
    # (1,1)->(1,2) and (2,1)->(2,2): serials and orgs overlap pairwise, so a
    # bug matching on a single column instead of the full tuple would leak.
    a1 = make(PowerCell, 1, 1, 'a1')
    b1 = make(PowerCell, 1, 2, 'b1')
    a2 = make(PowerCell, 2, 1, 'a2')
    b2 = make(PowerCell, 2, 2, 'b2')
    a1.add_child(b1)
    a2.add_child(b2)

    assert_equal %w[b1], a1.descendants.pluck(:name)
    assert_equal %w[b2], a2.descendants.pluck(:name)
    refute a1.ancestor_of?(b2)
    refute a2.ancestor_of?(b1)
    assert_equal %w[a1 a2], PowerCell.roots.order(:name).pluck(:name)
    assert_equal %w[b1 b2], PowerCell.leaves.order(:name).pluck(:name)
    assert_empty PowerCell.dag.validate
  end

  def test_diamond_path_count_and_deletion_maintenance
    a = make(PowerCell, 1, 1, 'a')
    b = make(PowerCell, 1, 2, 'b')
    c = make(PowerCell, 1, 3, 'c')
    d = make(PowerCell, 1, 4, 'd')
    a.add_child(b)
    a.add_child(c)
    b.add_child(d)
    c.add_child(d)

    row = PowerCell::DagPath.where(
      ancestor_ship_id: 1, ancestor_slot: 1, descendant_ship_id: 1, descendant_slot: 4
    ).sole

    assert_equal 2, row.path_count.to_i

    b.remove_child(d)

    assert a.ancestor_of?(d), 'a still reaches d through c'
    assert_empty PowerCell.dag.validate

    c.destroy!

    refute a.reload.ancestor_of?(d)
    assert_empty PowerCell.dag.validate
  end

  def test_between_subgraph_edges_and_topological_order
    a = make(PowerCell, 1, 1, 'a')
    b = make(PowerCell, 1, 2, 'b')
    c = make(PowerCell, 1, 3, 'c')
    d = make(PowerCell, 1, 4, 'd')
    off_path = make(PowerCell, 1, 5, 'off')
    a.add_child(b)
    a.add_child(c)
    b.add_child(d)
    c.add_child(d)
    a.add_child(off_path)

    assert_equal %w[a b c d], PowerCell.dag.between(a, d).order(:name).pluck(:name)
    assert_equal 5, a.subgraph_edges.count
    assert_topological_order PowerCell, PowerCell.topologically.to_a
    assert_topological_order PowerCell, a.descendants.topologically.to_a
  end

  def test_rebuild_and_validate
    a = make(PowerCell, 3, 1, 'a')
    b = make(PowerCell, 3, 2, 'b')
    a.add_child(b)

    PowerCell.dag.rebuild!

    assert_empty PowerCell.dag.validate
    PowerCell.dag.validate!
  end

  def test_recursive_cte_mode
    a = make(Antenna, 1, 1, 'a')
    b = make(Antenna, 1, 2, 'b')
    c = make(Antenna, 1, 3, 'c')
    other = make(Antenna, 2, 1, 'other') # shares slot with a
    a.add_child(b)
    b.add_child(c)

    assert_equal %w[b c], a.descendants.order(:name).pluck(:name)
    assert_equal %w[a b c], c.self_and_ancestors.order(:name).pluck(:name)
    assert a.ancestor_of?(c)
    refute a.ancestor_of?(other)
    assert_raises(DagMe::CycleError) { c.add_child(a) }
    assert_equal %w[a other], Antenna.roots.order(:name).pluck(:name)
    assert_topological_order Antenna, Antenna.topologically.to_a
  end
end
