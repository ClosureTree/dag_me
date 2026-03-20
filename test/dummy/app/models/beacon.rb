# frozen_string_literal: true

# Migration-lifecycle model: its dag objects are installed and removed by the
# generated migration under test, never at boot.
class Beacon < ApplicationRecord
  dag_me
end
