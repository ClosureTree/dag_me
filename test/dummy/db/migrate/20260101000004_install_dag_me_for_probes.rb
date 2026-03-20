# frozen_string_literal: true

class InstallDagMeForProbes < ActiveRecord::Migration[8.1]
  def up
    DagMe::DDL.install!(Probe)
  end

  def down
    DagMe::DDL.uninstall!(Probe)
  end
end
