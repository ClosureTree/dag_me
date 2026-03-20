# frozen_string_literal: true

class InstallDagMeForAntennas < ActiveRecord::Migration[8.1]
  def up
    DagMe::DDL.install!(Antenna)
  end

  def down
    DagMe::DDL.uninstall!(Antenna)
  end
end
