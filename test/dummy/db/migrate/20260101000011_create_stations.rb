# frozen_string_literal: true

# Schema-qualified node table: the dag lives in the orbital schema.
class CreateStations < ActiveRecord::Migration[8.1]
  def up
    execute 'CREATE SCHEMA IF NOT EXISTS orbital'
    create_table 'orbital.stations' do |t|
      t.text :name, null: false
    end
  end

  def down
    drop_table 'orbital.stations'
    execute 'DROP SCHEMA IF EXISTS orbital'
  end
end
