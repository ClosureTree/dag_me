# frozen_string_literal: true

# Multi-column scoped closure-backed model.
class Outpost < ApplicationRecord
  dag_me scope: %i[system_id sector]
end
