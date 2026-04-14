class Session < ApplicationRecord
  self.primary_key = :session_id

  has_many :pr_links, foreign_key: :session_id, dependent: :destroy
  has_many :messages, foreign_key: :session_id, dependent: :destroy
  has_many :file_history_snapshots, foreign_key: :session_id, dependent: :destroy

  has_many :user_prompts, through: :messages
  has_many :assistant_messages, through: :messages
  has_many :system_events, through: :messages

  scope :recent, -> { order(created_at: :desc) }
  scope :titled, -> { where.not(custom_title: nil) }

  def display_title
    custom_title.presence || inferred_title.presence || last_prompt&.truncate(80) || session_id
  end

  def total_input_tokens
    assistant_messages.sum(:input_tokens) +
      assistant_messages.sum(:cache_creation_input_tokens) +
      assistant_messages.sum(:cache_read_input_tokens)
  end

  def total_output_tokens
    assistant_messages.sum(:output_tokens)
  end

  def total_tokens
    total_input_tokens + total_output_tokens
  end

  def human_prompt_count
    messages.where(message_type: :user_prompt).count
  end

  def turn_count
    messages.joins(:system_event).where(system_events: { subtype: "turn_duration" }).count
  end

  def total_duration_ms
    system_events.where(subtype: "turn_duration").sum(:duration_ms)
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

  def base_project_path
    return project_path unless project_path
    project_path.sub(/--claude-worktrees-.*$/, "")
  end

  def worktree_name
    return nil unless project_path&.include?("--claude-worktrees-")
    project_path.split("--claude-worktrees-").last
  end

  def project_name
    project_path&.gsub(/^-/, "")&.gsub("-", "/") || "unknown"
  end

  def self.base_project_paths
    pluck(:project_path)
      .compact
      .map { |p| p.sub(/--claude-worktrees-.*$/, "") }
      .uniq
      .sort
  end
end
