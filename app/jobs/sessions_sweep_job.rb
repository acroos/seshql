# Walks every agent's session directory and enqueues anything that changed
# since it was last ingested.
class SessionsSweepJob < ApplicationJob
  queue_as :ingest

  def perform
    paths = Sessions::Adapters.discover
    return if paths.empty?

    watermarks = SessionFile.where(file_path: paths)
                            .pluck(:file_path, :file_mtime, :file_size)
                            .to_h { |path, mtime, size| [ path, [ mtime, size ] ] }

    enqueued = 0
    skipped = 0

    paths.each do |path|
      stat = File.stat(path)
      mtime, size = watermarks[path]

      if mtime && size == stat.size && mtime.to_i == stat.mtime.to_i
        skipped += 1
      else
        IngestSessionFileJob.perform_later(path)
        enqueued += 1
      end
    rescue Errno::ENOENT
      next
    end

    Rails.logger.info("[sweep] enqueued=#{enqueued} skipped=#{skipped} of #{paths.size} " \
                      "across #{Sessions::Adapters.enabled.map(&:label).join(', ')}")
  end
end
