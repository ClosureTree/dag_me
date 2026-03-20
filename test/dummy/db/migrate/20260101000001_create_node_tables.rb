# frozen_string_literal: true

# Node tables for every dag_me shape under test: classic bigint keys,
# uuid keys, scoped models, and composite keys.
class CreateNodeTables < ActiveRecord::Migration[8.1]
  def change
    create_table :missions do |t|
      t.text :name, null: false
    end

    create_table :maneuvers do |t|
      t.text :name, null: false
    end

    create_table :probes, id: :uuid, default: -> { 'uuidv7()' } do |t|
      t.text :name, null: false
    end

    create_table :satellites do |t|
      t.text :name, null: false
      t.bigint :constellation_id, null: false
    end

    create_table :outposts do |t|
      t.text :name, null: false
      t.bigint :system_id, null: false
      t.text :sector, null: false
    end

    create_table :power_cells, primary_key: %i[ship_id slot] do |t|
      t.bigint :ship_id, null: false
      t.bigint :slot, null: false
      t.text :name, null: false
    end

    create_table :antennas, primary_key: %i[ship_id slot] do |t|
      t.bigint :ship_id, null: false
      t.bigint :slot, null: false
      t.text :name, null: false
    end

    create_table :beacons do |t|
      t.text :name, null: false
    end
  end
end
