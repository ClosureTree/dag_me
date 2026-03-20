# frozen_string_literal: true

class InstallDagMeForManeuvers < ActiveRecord::Migration[8.1]
  def up
    DagMe::DDL.install!(Maneuver)
  end

  def down
    DagMe::DDL.uninstall!(Maneuver)
  end
end
