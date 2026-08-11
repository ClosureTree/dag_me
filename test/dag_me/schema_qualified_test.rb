# frozen_string_literal: true

require 'test_helper'

# Station's node table is "orbital.stations": generated tables and functions
# must land in the orbital schema while trigger names stay plain identifiers.
class SchemaQualifiedTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Station)
  end

  def test_configuration_names
    config = Station.dag_config

    assert_equal 'orbital', config.schema
    assert_equal 'station_dag', config.prefix
    assert_equal 'orbital.station_dag_edges', config.edge_table
    assert_equal 'orbital.station_dag_paths', config.paths_table
    assert_equal 'orbital.station_dag_lock', config.function_ref('lock')
    assert_equal 'station_dag_node_insert', config.trigger_name('node_insert')
  end

  def test_generated_objects_live_in_the_orbital_schema
    conn = Station.connection

    assert conn.table_exists?('orbital.station_dag_edges')
    assert conn.table_exists?('orbital.station_dag_paths')

    functions = conn.select_values(<<~SQL)
      SELECT p.proname FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'orbital' AND p.proname LIKE 'station\\_dag\\_%'
    SQL

    assert_includes functions, 'station_dag_lock'
    assert_includes functions, 'station_dag_edge_insert_check'
    assert_includes functions, 'station_dag_rebuild_paths'
  end

  def test_add_child_and_reachability
    nodes = build_dag(Station, %w[a>b a>c b>d c>d])

    assert_equal %w[b c], nodes['a'].children.order(:name).pluck(:name)
    assert_equal %w[b c d], nodes['a'].descendants.order(:name).pluck(:name)
    assert_equal %w[a b c], nodes['d'].ancestors.order(:name).pluck(:name)
    assert nodes['a'].ancestor_of?(nodes['d'])
  end

  def test_cycle_rejected
    nodes = build_dag(Station, %w[a>b b>c])

    assert_raises(DagMe::CycleError) { nodes['c'].add_child(nodes['a']) }
  end

  def test_cycle_rejected_for_raw_sql_writers
    nodes = build_dag(Station, %w[a>b b>c])

    error = assert_raises(ActiveRecord::StatementInvalid) do
      Station.connection.execute(
        "INSERT INTO orbital.station_dag_edges (parent_id, child_id) VALUES (#{nodes['c'].id}, #{nodes['a'].id})"
      )
    end
    assert_match(/cycle/, error.message)
  end

  def test_node_delete_shrinks_closure
    nodes = build_dag(Station, %w[a>b b>c])
    nodes['b'].destroy!

    assert_empty nodes['a'].reload.descendants
    assert_empty nodes['c'].reload.ancestors
  end

  def test_rebuild_and_validate
    build_dag(Station, %w[a>b a>c b>d c>d])

    Station.dag.rebuild!

    assert_predicate Station.dag, :valid?
  end

  def test_status_report_sees_schema_qualified_objects
    report = StringIO.new
    DagMe::TaskHelpers.status([Station], io: report)

    refute_match(/missing/, report.string)
    assert_match(/orbital\.station_dag_edges/, report.string)
  end
end

# Rails test environments set PostgreSQLAdapter.create_unlogged_tables for
# speed; generated tables must follow suit or their FKs to the (unlogged)
# node table are rejected by PostgreSQL.
class UnloggedTablesTest < Minitest::Test
  def test_install_sql_uses_unlogged_tables_when_adapter_flag_is_set
    adapter = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
    original = adapter.create_unlogged_tables
    adapter.create_unlogged_tables = true

    sql = DagMe::DDL.new(Station.dag_config).install_sql.join("\n")

    assert_includes sql, 'CREATE UNLOGGED TABLE orbital.station_dag_edges'
    assert_includes sql, 'CREATE UNLOGGED TABLE orbital.station_dag_paths'
  ensure
    adapter.create_unlogged_tables = original
  end

  def test_install_sql_uses_logged_tables_by_default
    sql = DagMe::DDL.new(Station.dag_config).install_sql.join("\n")

    assert_includes sql, 'CREATE TABLE orbital.station_dag_edges'
  end
end
