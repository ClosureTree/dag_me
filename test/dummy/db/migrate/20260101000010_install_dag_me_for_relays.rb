# frozen_string_literal: true

class InstallDagMeForRelays < ActiveRecord::Migration[8.1]
  def up
    DagMe::DDL.install!(Relay)
  end

  def down
    DagMe::DDL.uninstall!(Relay)
  end
end
