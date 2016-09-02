class Export < ApplicationRecord
  after_create :perform_lengthy_computation!

  def perform_lengthy_computation!
    sleep 2
  end
end
