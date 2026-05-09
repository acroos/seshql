class SessionsSweepJob < ApplicationJob
  queue_as :ingest

  PROJECTS_DIR = File.expand_path("~/.claude/projects").freeze

  def perform
    return unless Dir.exist?(PROJECTS_DIR)

    paths = Dir.glob(File.join(PROJECTS_DIR, "**", "*.jsonl"))
    return if paths.empty?

    session_ids = paths.map { |p| File.basename(p, ".jsonl") }
    watermarks = Session.where(session_id: session_ids).pluck(:session_id, :file_mtime, :file_size).to_h { |id, m, s| [ id, [ m, s ] ] }

    enqueued = 0
    skipped = 0

    paths.each do |path|
      stat = File.stat(path)
      session_id = File.basename(path, ".jsonl")
      mtime, size = watermarks[session_id]

      if mtime && size == stat.size && mtime.to_i == stat.mtime.to_i
        skipped += 1
      else
        IngestSessionFileJob.perform_later(path)
        enqueued += 1
      end
    rescue Errno::ENOENT
      next
    end

    Rails.logger.info("[sweep] enqueued=#{enqueued} skipped=#{skipped} of #{paths.size}")
  end
end
