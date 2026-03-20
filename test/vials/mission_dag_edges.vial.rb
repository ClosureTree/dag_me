# frozen_string_literal: true

# Every node in layer L (1..5) draws 3 parents from layer L-1 at positions
# (P + 0), (P + 7), (P + 13) mod 20 - offsets coprime with 20, so ancestry
# spreads across the whole layer and path counts fan out combinatorially.
# 5 child layers x 20 positions x 3 parents = 300 edges.
#
# Edge j (0-based): child layer = j / 60 + 1, position = (j % 60) / 3,
# parent offset slot = j % 3.
vial :mission_dag_edges do
  sequence(:id) { |i| i }

  sequence(:parent_id) do |i|
    j = i - 1
    layer = j / 60
    position = (j % 60) / 3
    offset = [0, 7, 13][j % 3]
    (layer * 20) + ((position + offset) % 20) + 1
  end

  sequence(:child_id) do |i|
    j = i - 1
    layer = (j / 60) + 1
    position = (j % 60) / 3
    (layer * 20) + position + 1
  end

  base do
    id sequence(:id)
    parent_id sequence(:parent_id)
    child_id sequence(:child_id)
  end

  generate 300
end
