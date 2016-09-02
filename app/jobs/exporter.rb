module Exporter
  @queue = :exports

  def self.perform(export_id)
    export = Export.find export_id
    export.perform_lengthy_computation!
  end
end
