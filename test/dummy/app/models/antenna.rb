# frozen_string_literal: true

# Composite primary key, CTE-backed.
class Antenna < ApplicationRecord
  self.primary_key = %i[ship_id slot]
  dag_me maintain: :recursive_cte
end
