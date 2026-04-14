class DashboardController < ApplicationController
  def index
    @total_sessions = Session.count
    @total_messages = Message.count
    @total_tokens = AssistantMessage.sum("input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens")
    @total_human_prompts = UserPrompt.count
    @total_tool_calls = ContentBlock.where(block_type: :tool_use).count
    @total_duration_ms = SystemEvent.where(subtype: "turn_duration").sum(:duration_ms)

    @recent_sessions = Session.recent.limit(10)

    @top_tools = ContentBlock
      .where(block_type: :tool_use)
      .group(:tool_name)
      .count
      .sort_by { |_, v| -v }
      .first(10)

    @model_usage = AssistantMessage
      .group(:model)
      .pluck(
        Arel.sql("model"),
        Arel.sql("COUNT(*)"),
        Arel.sql("SUM(input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens)")
      )
      .sort_by { |_, _, tokens| -(tokens || 0) }

    @projects = Session.pluck(:project_path)
      .compact
      .group_by { |p| p.sub(/--claude-worktrees-.*$/, "") }
      .transform_values(&:count)
      .sort_by { |_, v| -v }
      .first(15)

    @daily_sessions = Session
      .group("DATE(created_at)")
      .count
      .sort_by { |k, _| k || Date.new(2000, 1, 1) }
      .last(30)
  end
end
