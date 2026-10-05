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

  def test_status_reports_current_revision
    io = StringIO.new
    DagMe::TaskHelpers.status([Mission], io: io)

    assert_includes io.string, "functions at revision #{DagMe::DDL::REVISION}"
  end

  # A stamp that doesn't match the current revision means the function
  # bodies predate the gem; the doctor points at the refresh generator.
  def test_status_flags_outdated_functions
    build_dag(Mission, %w[a>b])
    Mission.connection.execute('COMMENT ON FUNCTION mission_dag_lock(text) IS NULL')
    io = StringIO.new
    DagMe::TaskHelpers.status([Mission], io: io)

    assert_includes io.string, 'rails generate dag_me:refresh Mission'
  ensure
    DagMe::DDL.refresh!(Mission)
  end

  def test_refresh_replaces_function_bodies_and_keeps_data
    nodes = build_dag(Mission, %w[a>b b>c a>c])
    conn = Mission.connection
    # A stale validate_paths(): plain SQL, same signature.
    conn.execute(<<~SQL)
      CREATE OR REPLACE FUNCTION mission_dag_validate_paths()
      RETURNS TABLE(ancestor_id bigint, descendant_id bigint, stored_min_depth integer,
                    stored_path_count numeric, true_min_depth integer, true_path_count numeric)
      LANGUAGE sql AS $$ SELECT NULL::bigint, NULL::bigint, NULL::int, NULL::numeric, NULL::int, NULL::numeric WHERE false $$;
    SQL
    conn.execute('COMMENT ON FUNCTION mission_dag_lock(text) IS NULL')
    conn.execute('ALTER TABLE mission_dag_paths RESET (fillfactor)')

    DagMe::DDL.refresh!(Mission)

    language = conn.select_value(<<~SQL)
      SELECT l.lanname FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
      WHERE p.proname = 'mission_dag_validate_paths'
    SQL

    assert_equal 'plpgsql', language
    stamp = conn.select_value("SELECT obj_description('mission_dag_lock(text)'::regprocedure)")

    assert_equal DagMe::DDL.revision_tag, stamp
    options = conn.select_value("SELECT reloptions::text FROM pg_class WHERE relname = 'mission_dag_paths'")

    assert_includes options, "fillfactor=#{DagMe::DDL::PATHS_FILLFACTOR}"
    assert_equal 3, Mission::DagEdge.count
    assert_dag_reachable nodes['a'], nodes['c']
    assert_dag_valid Mission
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
