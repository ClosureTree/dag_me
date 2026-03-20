# frozen_string_literal: true

class CreateRelays < ActiveRecord::Migration[8.1]
  def change
    create_table :relays do |t|
      t.text :name, null: false
    end
  end
end
