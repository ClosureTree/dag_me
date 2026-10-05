# frozen_string_literal: true

require 'test_helper'

# validate_paths() and rebuild_paths() recompute the closure from the edges
# by layering the nodes and aggregating per layer; enumerating paths would be
# exponential in the number of diamonds. These tests pin the recomputation to
# brute force on small graphs and to a time bound on graphs brute force
# cannot finish.
class TruthTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Mission)
    wipe!(PowerCell)
    wipe!(Satellite)
  end

  def test_rebuild_matches_path_enumeration_on_random_dags
    rng = Random.new(Minitest.seed || 7)

    4.times do |round|
      wipe!(Mission)
      order = Array.new(12) { |i| Mission.create!(name: "r#{round}n#{i}") }.shuffle(random: rng)
      # Edges only point forward in `order`: acyclic, and dense with diamonds.
      35.times do
        i, j = Array.new(2) { rng.rand(order.size) }.minmax
        next if i == j

        begin
          order[i].add_child(order[j])
        rescue ActiveRecord::RecordNotUnique
          # duplicate edge, skip
        end
      end

      truth = brute_force_closure(Mission)

      assert_equal truth, stored_closure(Mission), "round #{round}: triggers disagree with path enumeration"
      assert_empty Mission.dag.validate

      Mission.connection.execute('DELETE FROM mission_dag_paths')
      Mission.dag.rebuild!

      assert_equal truth, stored_closure(Mission), "round #{round}: rebuild disagrees with path enumeration"
    end
  end

  # 2**64 paths between the ends. Path enumeration never returns here.
  def test_long_diamond_chain_validates_and_rebuilds
    first, last = diamond_chain(Mission, 64)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_empty Mission.dag.validate
    Mission.connection.execute('DELETE FROM mission_dag_paths')
    Mission.dag.rebuild!
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    row = Mission::DagPath.find_by!(ancestor_id: first.id, descendant_id: last.id)

    assert_equal 2**64, row.path_count.to_i
    assert_equal 128, row.min_depth
    assert_operator elapsed, :<, 30, "validate + rebuild took #{elapsed.round(1)}s"
    assert_empty Mission.dag.validate
  end

  def test_rebuild_reproduces_trigger_closure_for_composite_keys
    cells = Array.new(8) { |i| PowerCell.create!(ship_id: 1, slot: i, name: "c#{i}") }
    [[0, 1], [0, 2], [1, 3], [2, 3], [3, 4], [1, 5], [5, 4], [4, 6], [2, 7]].each do |p, c|
      cells[p].add_child(cells[c])
    end
    expected = closure_rows(PowerCell)

    PowerCell.connection.execute('DELETE FROM power_cell_dag_paths')
    PowerCell.dag.rebuild!

    assert_equal expected, closure_rows(PowerCell)
    assert_empty PowerCell.dag.validate
  end

  def test_rebuild_restamps_scope_columns
    tenants = { 1 => %w[a>b a>c b>d c>d], 2 => %w[w>x x>y w>y] }
    tenants.each { |id, spec| build_dag(Satellite, spec, constellation_id: id) }
    expected = closure_rows(Satellite)

    Satellite.connection.execute('DELETE FROM satellite_dag_paths')
    Satellite.dag.rebuild!

    assert_equal expected, closure_rows(Satellite)
    assert_empty Satellite.dag.validate
  end

  # Only edges written with triggers disabled can form a cycle. Path
  # enumeration looped forever on them; now both entry points refuse.
  def test_cyclic_edges_raise_instead_of_hanging
    conn = Mission.connection
    a = Mission.create!(name: 'a')
    b = Mission.create!(name: 'b')
    c = Mission.create!(name: 'c')
    conn.execute('ALTER TABLE mission_dag_edges DISABLE TRIGGER USER')
    Mission::DagEdge.insert_all!([{ parent_id: a.id, child_id: b.id },
                                  { parent_id: b.id, child_id: c.id },
                                  { parent_id: c.id, child_id: b.id }])

    assert_raises(DagMe::CycleError) { Mission.dag.validate }
    assert_raises(DagMe::CycleError) { Mission.dag.rebuild! }
  ensure
    Mission::DagEdge.delete_all
    conn.execute('ALTER TABLE mission_dag_edges ENABLE TRIGGER USER')
  end

  # Inside a caller's transaction the function holds SHARE locks; the
  # caller's own writes must still go through.
  def test_validate_inside_an_open_transaction
    nodes = build_dag(Mission, %w[a>b b>c a>c])

    Mission.transaction do
      assert_empty Mission.dag.validate
      nodes['c'].add_child(Mission.create!(name: 'd'))

      assert_empty Mission.dag.validate
    end

    assert_dag_reachable nodes['a'], Mission.find_by!(name: 'd')
  end
end
