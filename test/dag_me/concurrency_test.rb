# frozen_string_literal: true

require 'test_helper'

# Two writers racing opposite edges (a -> b and b -> a) must never commit a
# cycle: the BEFORE INSERT trigger serializes them on the advisory lock, and
# the loser's cycle check runs against the winner's committed closure.
class ConcurrencyTest < Minitest::Test
  include DagTestHelpers

  ROUNDS = 15

  def setup
    wipe!(Mission)
  end

  def test_reverse_edge_race_never_commits_cycle
    ROUNDS.times do |round|
      a = Mission.create!(name: "a#{round}")
      b = Mission.create!(name: "b#{round}")

      outcomes = [[a, b], [b, a]].map do |parent, child|
        Thread.new do
          Mission.connection_pool.with_connection do
            parent.add_child(child)
            :committed
          rescue DagMe::CycleError
            :rejected
          end
        end
      end.map(&:value)

      assert_equal %i[committed rejected], outcomes.sort,
                   "round #{round}: exactly one of the racing edges must win"
      assert_equal 1, Mission::DagEdge.where(parent_id: [a.id, b.id]).count
      assert_empty Mission.dag.validate, "round #{round}: closure diverged"
    end
  end

  # Above READ COMMITTED the loser's recheck would run on a pre-lock snapshot.
  def test_writes_require_read_committed_isolation
    a = Mission.create!(name: 'iso-a')
    b = Mission.create!(name: 'iso-b')

    assert_raises(DagMe::IsolationError) do
      Mission.transaction(isolation: :repeatable_read) { a.add_child(b) }
    end

    a.add_child(b)

    assert_raises(DagMe::IsolationError) do
      Mission.transaction(isolation: :serializable) { a.remove_child(b) }
    end

    assert a.ancestor_of?(b), 'graph must be untouched by refused writes'
    assert_empty Mission.dag.validate
  end

  def test_concurrent_inserts_into_shared_diamond
    root = Mission.create!(name: 'root')
    sink = Mission.create!(name: 'sink')
    middles = Array.new(6) { |i| Mission.create!(name: "m#{i}") }

    middles.map do |middle|
      Thread.new do
        Mission.connection_pool.with_connection do
          root.add_child(middle)
          middle.add_child(sink)
        end
      end
    end.each(&:join)

    row = Mission::DagPath.find_by!(ancestor_id: root.id, descendant_id: sink.id)

    assert_equal middles.length, row.path_count.to_i
    assert_empty Mission.dag.validate
  end
end
