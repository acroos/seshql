class IngestionRun < ApplicationRecord
  STATUSES = %w[succeeded failed skipped].freeze

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(run_at: :desc) }
  scope :failures, -> { where(status: "failed") }

  def succeeded? = status == "succeeded"
  def failed?    = status == "failed"
  def skipped?   = status == "skipped"
end
