# frozen_string_literal: true

require 'test_helper'

# Mutates a random DAG and checks the trigger-maintained closure against the
# recursive-CTE truth after every single operation. This is the safety net for
# the dangerous path: incremental deletion (path_count decrement + min_depth
# repair).
class PropertyTest < Minitest::Test
  include DagTestHelpers

  NODES = 14
  OPERATIONS = 120

  def setup
    wipe!(Mission)
    wipe!(Satellite)
  end

  def test_random_mutations_keep_closure_exact
    rng = Random.new(Minitest.seed || 42)
    nodes = Array.new(NODES) { |i| Mission.create!(name: "n#{i}") }
    edges = []

    OPERATIONS.times do |op|
      roll = rng.rand
      if roll < 0.55 || edges.empty?
        parent, child = nodes.compact.sample(2, random: rng)
        next if parent.nil? || child.nil?

        begin
          parent.add_child(child)
          edges << [parent.id, child.id]
        rescue DagMe::CycleError, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid
          # rejected edge: fine, the graph is unchanged
        end
      elsif roll < 0.85
        parent_id, child_id = edges.delete_at(rng.rand(edges.length))
        Mission::DagEdge.where(parent_id: parent_id, child_id: child_id).delete_all
      else
        idx = rng.rand(nodes.length)
        node = nodes[idx]
        next if node.nil?

        node.destroy!
        nodes[idx] = nil
        edges.reject! { |p, c| p == node.id || c == node.id }
      end

      discrepancies = Mission.dag.validate

      assert_empty discrepancies,
                   "closure diverged from CTE truth after operation #{op}: #{discrepancies.inspect}"
    end

    # Cross-check the two adapters agree on a few nodes at the end.
    cte = DagMe::Adapters::RecursiveCte.new(Mission.dag_config)
    nodes.compact.sample(5, random: rng).each do |node|
      assert_equal cte.descendants(node).order(:id).pluck(:id),
                   node.descendants.order(:id).pluck(:id),
                   "adapters disagree on descendants of #{node.name}"
      assert_equal cte.ancestors(node).order(:id).pluck(:id),
                   node.ancestors.order(:id).pluck(:id),
                   "adapters disagree on ancestors of #{node.name}"
    end
  end

  # Same storm, two tenants: mutations stay scope-correct, occasional
  # cross-tenant edges are rejected, and validation covers scope stamps too.
  def test_random_mutations_scoped
    rng = Random.new((Minitest.seed || 42) + 1)
    tenants = [1, 2]
    nodes = tenants.to_h { |t| [t, Array.new(7) { |i| Satellite.create!(name: "t#{t}n#{i}", constellation_id: t) }] }
    edges = []

    80.times do |op|
      tenant = tenants.sample(random: rng)
      pool = nodes[tenant].compact
      roll = rng.rand

      if roll < 0.1
        other = (tenants - [tenant]).first
        foreign = nodes[other].compact.sample(random: rng)
        local = pool.sample(random: rng)
        assert_raises(DagMe::ScopeError) { local.add_child(foreign) } if local && foreign
      elsif roll < 0.6 || edges.none? { |t, _, _| t == tenant }
        parent, child = pool.sample(2, random: rng)
        next if parent.nil? || child.nil?

        begin
          parent.add_child(child)
          edges << [tenant, parent.id, child.id]
        rescue DagMe::CycleError, ActiveRecord::RecordNotUnique
          # rejected edge: fine, the graph is unchanged
        end
      else
        tenant_edges = edges.select { |t, _, _| t == tenant }
        _, parent_id, child_id = tenant_edges.sample(random: rng)
        Satellite::DagEdge.where(parent_id: parent_id, child_id: child_id).delete_all
        edges.delete([tenant, parent_id, child_id])
      end

      discrepancies = Satellite.dag.validate

      assert_empty discrepancies,
                   "scoped closure diverged after operation #{op}: #{discrepancies.inspect}"
    end

    tenants.each do |tenant|
      stamped = Satellite::DagPath.where(ancestor_id: nodes[tenant].map(&:id)).distinct.pluck(:constellation_id)

      assert_equal [tenant], stamped, "tenant #{tenant} closure rows leaked scope"
    end
  end
end
