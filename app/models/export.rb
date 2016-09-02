class Export < ApplicationRecord
  def async_populate!
    Resque.enqueue Exporter, id
  end

  def perform_lengthy_computation!
    sleep 2

    self.complete = true
    self.save
  end
end
