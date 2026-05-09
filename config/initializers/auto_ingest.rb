Rails.application.config.after_initialize do
  next if Rails.env.test?
  next if ENV["AUTO_INGEST"] == "false"
  next unless defined?(Rails::Server)

  Thread.new do
    sleep 1
    begin
      SessionsSweepJob.perform_later
      Rails.logger.info("[auto_ingest] enqueued initial sweep")
    rescue => e
      Rails.logger.warn("[auto_ingest] failed to enqueue sweep: #{e.message}")
    end
  end
end
