# frozen_string_literal: true

# One node, many networks: the same relay station participates in an
# energy-distribution DAG and an independent comms-routing DAG.
class Relay < ApplicationRecord
  dag_me :power
  dag_me :comms, maintain: :recursive_cte
end
