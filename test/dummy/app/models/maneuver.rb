# frozen_string_literal: true

# CTE-backed model, exercising the adapter seam.
class Maneuver < ApplicationRecord
  dag_me maintain: :recursive_cte
end
