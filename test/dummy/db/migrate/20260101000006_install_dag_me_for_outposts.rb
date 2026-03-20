# frozen_string_literal: true

class InstallDagMeForOutposts < ActiveRecord::Migration[8.1]
  def up
    DagMe::DDL.install!(Outpost)
  end

  def down
    DagMe::DDL.uninstall!(Outpost)
  end
end
