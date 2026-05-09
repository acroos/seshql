class IngestSessionFileJob < ApplicationJob
  queue_as :ingest

  def perform(file_path)
    Sessions::Ingester.call(file_path)
  end
end
