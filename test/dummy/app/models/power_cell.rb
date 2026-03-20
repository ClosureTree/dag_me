# frozen_string_literal: true

# Composite primary key, closure-backed. The key must be declared before the
# macro; dag_me reads the declaration, not the schema.
class PowerCell < ApplicationRecord
  self.primary_key = %i[ship_id slot]
  dag_me
end
