# frozen_string_literal: true

# A layered DAG: 6 layers x 20 nodes. Node (layer L, position P) has
# id = L * 20 + P + 1. Edges live in mission_dag_edges.vial.rb.
vial :missions do
  sequence(:id) { |i| i }
  sequence(:name) { |i| "mission_l#{(i - 1) / 20}_p#{(i - 1) % 20}" }

  base do
    id sequence(:id)
    name sequence(:name)
  end

  generate 120
end
