# One transcript file on disk, and how far into it ingestion has read.
#
# Kept separate from `sessions` because the relationship is not one-to-one:
# a Codex thread that has been reverted keeps its id but starts a new rollout
# file, so a single session can be assembled from several files.
class SessionFile < ApplicationRecord
  belongs_to :session, foreign_key: :session_id, optional: true

  enum :source, { claude_code: "claude_code", codex: "codex" }, validate: true

  scope :stale, -> { where(last_ingested_at: nil) }
end
