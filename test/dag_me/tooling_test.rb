# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class ToolingTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Mission)
  end

  def test_shipped_test_helper_assertions
    assert_dag_model Mission, maintain: :postgresql_closure
    assert_dag_model Maneuver, maintain: :recursive_cte
    assert_dag_model Satellite, scope: :constellation_id
    assert_dag_model Outpost, scope: %i[system_id sector]
    assert_dag_valid Mission

    nodes = build_dag(Mission, %w[a>b])

    assert_dag_reachable nodes['a'], nodes['b']
    refute_dag_reachable nodes['b'], nodes['a']
  end

  def test_status_reports_healthy_models
    build_dag(Mission, %w[a>b])
    io = StringIO.new
    DagMe::TaskHelpers.status([Mission, Maneuver, Satellite, Outpost], io: io)
    report = io.string

    assert_includes report, 'Mission'
    assert_includes report, 'closure valid'
    assert_includes report, 'not materialized (recursive_cte)'
    assert_includes report, 'scope: system_id'
    assert_includes report, 'scope: system_id, sector'
    refute_includes report, '✗'
  end

  def test_status_flags_missing_objects
    io = StringIO.new
    Mission.connection.execute('DROP TRIGGER mission_dag_edge_delete_apply ON mission_dag_edges;')
    DagMe::TaskHelpers.status([Mission], io: io)

    assert_includes io.string, 'trigger mission_dag_edge_delete_apply missing'
  ensure
    Mission.connection.execute(<<~SQL)
      CREATE TRIGGER mission_dag_edge_delete_apply AFTER DELETE ON mission_dag_edges
        FOR EACH ROW EXECUTE FUNCTION mission_dag_edge_delete_apply();
    SQL
  end
end
