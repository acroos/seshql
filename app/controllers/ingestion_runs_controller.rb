class IngestionRunsController < ApplicationController
  def index
    @runs = IngestionRun.recent.limit(50)
    @failure_count = IngestionRun.failures.where("run_at > ?", 24.hours.ago).count
  end

  def retry
    run = IngestionRun.find(params[:id])
    IngestSessionFileJob.perform_later(run.file_path)
    redirect_to ingestion_runs_path, notice: "Re-enqueued ingestion for #{File.basename(run.file_path)}"
  end
end
