# frozen_string_literal: true

module Fleet
  # Namespaced model for the generators: migration names must come from the
  # full class path (fleet_sorties), not the last segment. Shares Mission's
  # tables, so it needs no schema of its own.
  class Sortie < ApplicationRecord
    self.table_name = 'missions'
    dag_me
  end
end
