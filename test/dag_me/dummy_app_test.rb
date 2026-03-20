# frozen_string_literal: true

require 'test_helper'
require 'rails/generators'
require 'generators/dag_me/migration_generator'
require 'rake'
require 'stringio'
require 'tmpdir'

# End-to-end through the dummy Rails app: railtie, generator, generated
# migration up/down, and the rake missions.
class DummyAppTest < Minitest::Test
  include DagTestHelpers

  def setup
    wipe!(Mission)
  end

  def test_railtie_is_wired
    assert defined?(DagMe::Railtie)
    assert_kind_of Dummy::Application, Rails.application
  end

  def test_generator_creates_migration
    Dir.mktmpdir do |dir|
      quietly { DagMe::Generators::MigrationGenerator.start(['Beacon'], destination_root: dir) }
      file = Dir[File.join(dir, 'db/migrate/*_install_dag_me_for_beacons.rb')].sole
      content = File.read(file)

      assert_match(/class InstallDagMeForBeacons < ActiveRecord::Migration\[\d+\.\d+\]/, content)
      assert_includes content, 'DagMe::DDL.install!(Beacon)'
      assert_includes content, 'DagMe::DDL.uninstall!(Beacon)'
    end
  end

  def test_generated_migration_up_down
    conn = ActiveRecord::Base.connection
    migration = generate_and_load_migration('Beacon')

    quietly { migration.migrate(:up) }

    assert conn.table_exists?('beacon_dag_edges')
    assert conn.table_exists?('beacon_dag_paths')

    a = Beacon.create!(name: 'a')
    b = Beacon.create!(name: 'b')
    a.add_child(b)

    assert a.ancestor_of?(b)
    assert_raises(DagMe::CycleError) { b.add_child(a) }
    assert_empty Beacon.dag.validate

    Beacon.delete_all
    quietly { migration.migrate(:down) }

    refute conn.table_exists?('beacon_dag_edges')
    refute conn.table_exists?('beacon_dag_paths')
  ensure
    DagMe::DDL.uninstall!(Beacon) if ActiveRecord::Base.connection.table_exists?('beacon_dag_edges')
  end

  def test_rake_status_reports_models
    build_dag(Mission, %w[a>b])
    out = run_rake('dag_me:status')

    assert_includes out, 'Mission'
    assert_includes out, 'closure valid'
  end

  def test_rake_rebuild_single_model
    build_dag(Mission, %w[a>b])
    out = run_rake('dag_me:rebuild', env: { 'MODEL' => 'Mission' })

    assert_includes out, 'Rebuilding Mission... done'
    assert_empty Mission.dag.validate
  end

  def test_rake_rebuild_rejects_non_dag_model
    assert_raises(SystemExit) do
      capture_io { run_rake('dag_me:rebuild', env: { 'MODEL' => 'String' }) }
    end
  end

  private

  def generate_and_load_migration(model_name)
    dir = Dir.mktmpdir
    quietly { DagMe::Generators::MigrationGenerator.start([model_name], destination_root: dir) }
    file = Dir[File.join(dir, 'db/migrate/*.rb')].sole
    load file
    Object.const_get("InstallDagMeFor#{model_name.pluralize}")
  end

  def run_rake(task_name, env: {})
    rake = Rake::Application.new
    Rake.application = rake
    Rake::Task.define_task(:environment)
    load File.expand_path('../../lib/dag_me/railties/tasks.rake', __dir__)

    previous = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
    env.each { |k, v| ENV[k] = v }
    out, = capture_io { rake[task_name].invoke }
    out
  ensure
    previous&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def quietly(&)
    capture_io(&)
  end
end
