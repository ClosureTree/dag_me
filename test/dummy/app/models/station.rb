# frozen_string_literal: true

# Schema-qualified node table ("orbital.stations"), closure-backed.
class Station < ApplicationRecord
  self.table_name = 'orbital.stations'

  dag_me
end
