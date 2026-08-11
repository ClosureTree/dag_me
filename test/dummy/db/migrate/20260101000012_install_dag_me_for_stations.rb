# frozen_string_literal: true

class InstallDagMeForStations < ActiveRecord::Migration[8.1]
  def up
    DagMe::DDL.install!(Station)
  end

  def down
    DagMe::DDL.uninstall!(Station)
  end
end
