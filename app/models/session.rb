class Session < ApplicationRecord
  self.primary_key = :session_id

  belongs_to :repo, optional: true
  has_many :session_files, foreign_key: :session_id, dependent: :destroy
  has_many :pr_links, foreign_key: :session_id, dependent: :destroy
  has_many :messages, foreign_key: :session_id, dependent: :destroy
  has_many :file_history_snapshots, foreign_key: :session_id, dependent: :destroy

  has_many :user_prompts, through: :messages
  has_many :assistant_messages, through: :messages
  has_many :system_events, through: :messages

  # Which agent produced the session. Adds `Session.codex` /
  # `Session.claude_code` scopes for filtering.
  enum :source, { claude_code: "claude_code", codex: "codex" }, validate: true

  scope :recent, -> { order(created_at: :desc) }
  scope :titled, -> { where.not(custom_title: nil) }
  scope :in_directory, ->(path) { where(directory: path) }

  def agent_label
    Sessions::Adapters.for_source(source)&.label || source
  end

  def repo_name
    repo&.repo_name
  end

  def display_label
    head = repo_name.presence || directory_name.presence || "?"
    qualifier = worktree.presence || branch.presence
    "#{head}#{"@#{qualifier}" if qualifier} — #{title}"
  end

  def directory_name
    directory.presence && File.basename(directory)
  end

  def total_tokens
    total_input_tokens + total_output_tokens
  end

  # Input tokens that were neither written to nor read from the prompt cache —
  # the genuinely new context the model had to read at the full rate.
  def fresh_input_tokens
    total_input_tokens - total_cache_creation_tokens - total_cache_read_tokens
  end

  def turn_count
    messages.joins(:system_event).where(system_events: { subtype: "turn_duration" }).count
  end

  # Wall-clock span from the first to the last message. Much larger than
  # active_duration_ms for sessions that were resumed hours or days later.
  def span_ms
    return nil unless created_at && ended_at
    ((ended_at - created_at) * 1000).round
  end

  def tool_usage_summary
    ContentBlock
      .joins(assistant_message: :message)
      .where(messages: { session_id: session_id })
      .where(block_type: :tool_use)
      .group(:tool_name)
      .count
      .sort_by { |_, v| -v }
  end

  # Every working directory sessions have been run in, for the filter pills.
  def self.directories
    distinct.where.not(directory: nil).pluck(:directory).sort
  end
end
