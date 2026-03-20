# frozen_string_literal: true

class InstallDagMeForMissions < ActiveRecord::Migration[8.1]
  def up
    DagMe::DDL.install!(Mission)
  end

  def down
    DagMe::DDL.uninstall!(Mission)
  end
end
