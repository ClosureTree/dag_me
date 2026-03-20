# frozen_string_literal: true

class InstallDagMeForPowerCells < ActiveRecord::Migration[8.1]
  def up
    DagMe::DDL.install!(PowerCell)
  end

  def down
    DagMe::DDL.uninstall!(PowerCell)
  end
end
