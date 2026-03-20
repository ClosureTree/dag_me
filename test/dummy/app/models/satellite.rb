# frozen_string_literal: true

# Scoped (multi-tenant) closure-backed model.
class Satellite < ApplicationRecord
  dag_me scope: :constellation_id
end
