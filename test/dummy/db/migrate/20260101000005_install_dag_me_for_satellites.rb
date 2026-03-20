# frozen_string_literal: true

class InstallDagMeForSatellites < ActiveRecord::Migration[8.1]
  def up
    DagMe::DDL.install!(Satellite)
  end

  def down
    DagMe::DDL.uninstall!(Satellite)
  end
end
