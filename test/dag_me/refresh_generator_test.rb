# frozen_string_literal: true

require 'test_helper'
require 'rails/generators'
require 'generators/dag_me/refresh_generator'
require 'tmpdir'

# rails generate dag_me:refresh: the migration must load under the name Rails
# derives from its file, and must replay without the model it was generated
# from (models get renamed; migrations stay).
class RefreshGeneratorTest < Minitest::Test
  include DagTestHelpers

  # Every dummy model whose graph the test database installs.
  INSTALLED = [Mission, Maneuver, Probe, Satellite, Outpost, PowerCell, Antenna, Relay, Station].freeze

  def test_names_the_migration_after_the_revision
    file = generate('Mission')
    revision = DagMe::DDL::REVISION

    assert_match(/_refresh_dag_me_r#{revision}_for_missions\.rb\z/, file)
    assert_match(/class RefreshDagMeR#{revision}ForMissions < ActiveRecord::Migration\[\d+\.\d+\]/, File.read(file))
  end

  def test_pins_the_dag_to_its_table_and_options
    content = File.read(generate('Relay'))

    assert_includes content, 'refresh "relays", name: :power, maintain: :postgresql_closure, prefix: "relay_power_dag"'
    assert_includes content, 'refresh "relays", name: :comms, maintain: :recursive_cte, prefix: "relay_comms_dag"'
    refute_includes content, 'DagMe::DDL.refresh!(Relay)'
  end

  # file_name is only the last segment: Fleet::Sortie used to produce
  # ..._for_sorties.rb declaring RefreshDagMeR2ForFleet::Sorties, which Rails
  # cannot load.
  def test_namespaced_model_file_and_class_agree
    file = generate('Fleet::Sortie')

    assert_match(/_for_fleet_sorties\.rb\z/, file)
    assert_operator load_migration(file), :<, ActiveRecord::Migration
  end

  def test_migration_runs_without_the_model_constant
    file = generate('Fleet::Sortie')
    Mission.connection.execute('COMMENT ON FUNCTION mission_dag_lock(text) IS NULL')
    sortie = Fleet.send(:remove_const, :Sortie)

    quietly { load_migration(file).migrate(:up) }

    assert_equal :current, DagMe::TaskHelpers.installed_revision(Mission, Mission.dag_configs[:default])
  ensure
    Fleet.const_set(:Sortie, sortie) if sortie
    DagMe::DDL.refresh!(Mission)
  end

  # Running the generated migration executes exactly what DDL.refresh!(model)
  # would: composite keys, scopes, named and CTE dags, schema-qualified tables.
  def test_replays_refresh_sql_for_every_installed_model
    INSTALLED.each do |model|
      expected = model.dag_configs.each_value.flat_map do |config|
        ddl = DagMe::DDL.new(config)
        ddl.function_sql + ddl.storage_sql
      end
      migration = load_migration(generate(model.name))

      assert_equal expected, executed_sql { quietly { migration.migrate(:up) } }, model.name
    end
  end

  # Table overrides are omitted when derived, kept when declared.
  def test_snapshot_round_trips_every_option
    config = DagMe::Configuration.new(model: Mission, name: :escort, scope: :fleet_id, prefix: 'escort_dag',
                                      edge_table: 'escort_links', paths_table: 'escort_reach')
    options = DagMe::Generators::RefreshGenerator.snapshot(config)
    stand_in = Class.new(ActiveRecord::Base) { self.table_name = 'missions' }
    copy = DagMe::Configuration.new(model: stand_in, **options)

    attrs = %i[name maintain scope_columns prefix schema edge_table paths_table node_table]

    assert_equal attrs.to_h { |attr| [attr, config.public_send(attr)] },
                 attrs.to_h { |attr| [attr, copy.public_send(attr)] }
    refute_includes DagMe::Generators::RefreshGenerator.snapshot(Mission.dag_configs[:default]).keys, :edge_table
  end

  def test_rejects_models_without_dag_me
    %w[String Nope].each do |name|
      Dir.mktmpdir do |dir|
        _, err = capture_io { DagMe::Generators::RefreshGenerator.start([name], destination_root: dir) }

        assert_includes err, "#{name} is not a dag_me model"
        assert_empty Dir[File.join(dir, 'db/migrate/*.rb')]
      end
    end
  end

  private

  def generate(model_name)
    dir = Dir.mktmpdir
    quietly { DagMe::Generators::RefreshGenerator.start([model_name], destination_root: dir) }
    Dir[File.join(dir, 'db/migrate/*.rb')].sole
  end

  # Loads the migration under the constant Rails derives from the file name,
  # then detaches it so later loads start clean.
  def load_migration(file)
    load file
    Object.send(:remove_const, File.basename(file, '.rb').sub(/\A\d+_/, '').camelize)
  end

  def executed_sql(&)
    statements = []
    collect = lambda do |*, payload|
      statements << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(collect, 'sql.active_record', &)
    statements
  end

  def quietly(&)
    capture_io(&)
  end
end
